import Foundation

enum DownloaderServiceError: LocalizedError {
    case missingRequiredTool(String)
    case invalidURL
    case metadataFailed(String)
    case metadataTimeout(Int)
    case invalidMetadata
    case processStartFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingRequiredTool(tool):
            return "Missing required tool: \(tool)."
        case .invalidURL:
            return "Please enter a valid URL."
        case let .metadataFailed(message):
            return "Metadata extraction failed: \(message)"
        case let .metadataTimeout(seconds):
            return "Metadata analysis timed out after \(seconds)s."
        case .invalidMetadata:
            return "Could not parse media metadata from yt-dlp output."
        case let .processStartFailed(message):
            return "Download process could not start: \(message)"
        }
    }
}

final class ActiveDownloadProcess: @unchecked Sendable {
    private let process: Process
    private let stdoutReader: LinePipeReader
    private let stderrReader: LinePipeReader

    init(process: Process, stdoutReader: LinePipeReader, stderrReader: LinePipeReader) {
        self.process = process
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func waitForExit(_ completion: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread { [self] in
            self.process.waitUntilExit()
            self.stdoutReader.stop()
            self.stderrReader.stop()
            completion(self.process.terminationStatus)
        }
    }
}

final class LinePipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let onLine: (String) -> Void
    private var buffer = Data()
    private let lock = NSLock()

    init(fileHandle: FileHandle, onLine: @escaping (String) -> Void) {
        self.fileHandle = fileHandle
        self.onLine = onLine
        start()
    }

    func stop() {
        fileHandle.readabilityHandler = nil
        flushBuffer()
    }

    private func start() {
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData

            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flushBuffer()
                return
            }

            self.append(data)
        }
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0..<newlineRange.upperBound)
            lock.unlock()

            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty {
                onLine(line)
            }

            lock.lock()
        }

        lock.unlock()
    }

    private func flushBuffer() {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else {
            return
        }

        if let line = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty {
            onLine(line)
        }

        buffer.removeAll(keepingCapacity: false)
    }
}

final class YtDlpService: @unchecked Sendable {
    private let fileManager = FileManager.default

    struct FormatExpressionPlan: Equatable {
        let expression: String
        let expectsMergedAudio: Bool
        let downgradedToBestWithoutFFmpeg: Bool
        let warningMessage: String?
    }

    func fetchVideoInfo(
        for sourceURL: String,
        toolchain: ToolchainStatus,
        options: DownloadOptions?
    ) async throws -> VideoInfo {
        if let localInfoPath = resolveLocalInfoJsonPath(from: sourceURL) {
            return try loadVideoInfo(fromJsonFile: localInfoPath)
        }

        guard let ytDlpPath = toolchain.ytDlpPath else {
            throw DownloaderServiceError.missingRequiredTool("yt-dlp")
        }
        let normalizedSourceURL = normalizeSourceURL(sourceURL)
        guard URL(string: normalizedSourceURL) != nil else {
            throw DownloaderServiceError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: ytDlpPath)
                    var arguments: [String] = [
                        "--dump-single-json",
                        "--no-playlist",
                        "--skip-download",
                        "--no-warnings"
                    ]
                    self.appendNetworkContextArguments(
                        to: &arguments,
                        options: options,
                        sourceURL: normalizedSourceURL
                    )
                    arguments.append(normalizedSourceURL)
                    process.arguments = arguments

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()
                    let timeoutSeconds = 40
                    let timeoutDeadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

                    while process.isRunning, Date() < timeoutDeadline {
                        Thread.sleep(forTimeInterval: 0.2)
                    }

                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                        _ = stdout.fileHandleForReading.readDataToEndOfFile()
                        _ = stderr.fileHandleForReading.readDataToEndOfFile()
                        throw DownloaderServiceError.metadataTimeout(timeoutSeconds)
                    }

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                    guard process.terminationStatus == 0 else {
                        let stderrText = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw DownloaderServiceError.metadataFailed(stderrText ?? "yt-dlp exited with code \(process.terminationStatus)")
                    }

                    let info = try Self.parseVideoInfo(data: outputData, sourceURL: normalizedSourceURL)
                    continuation.resume(returning: info)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startDownload(
        request: DownloadRequest,
        toolchain: ToolchainStatus,
        onLog: @escaping (String) -> Void,
        onProgress: @escaping (DownloadProgressUpdate) -> Void
    ) throws -> ActiveDownloadProcess {
        guard let ytDlpPath = toolchain.ytDlpPath else {
            throw DownloaderServiceError.missingRequiredTool("yt-dlp")
        }

        let outputDirectory = URL(fileURLWithPath: request.outputDirectory)
        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        let argumentPlan = buildDownloadArguments(request: request, toolchain: toolchain)
        process.arguments = argumentPlan.arguments
        if let warning = argumentPlan.formatPlan.warningMessage {
            onLog("Warning: \(warning)")
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineHandler: (String) -> Void = { line in
            if let progress = Self.parseProgress(from: line) {
                onProgress(progress)
                return
            }

            onLog(line)
        }

        let stdoutReader = LinePipeReader(
            fileHandle: stdoutPipe.fileHandleForReading,
            onLine: lineHandler
        )
        let stderrReader = LinePipeReader(
            fileHandle: stderrPipe.fileHandleForReading,
            onLine: lineHandler
        )

        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            throw DownloaderServiceError.processStartFailed(error.localizedDescription)
        }

        return ActiveDownloadProcess(
            process: process,
            stdoutReader: stdoutReader,
            stderrReader: stderrReader
        )
    }

    private struct DownloadArgumentsPlan {
        let arguments: [String]
        let formatPlan: FormatExpressionPlan
    }

    private func buildDownloadArguments(request: DownloadRequest, toolchain: ToolchainStatus) -> DownloadArgumentsPlan {
        let outputTemplate: String
        if let customFileName = request.customFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customFileName.isEmpty {
            outputTemplate = "\(sanitizeFileName(customFileName)).%(ext)s"
        } else {
            outputTemplate = "%(title).180B [%(id)s].%(ext)s"
        }

        var arguments: [String] = [
            "--newline",
            "--continue",
            "--no-playlist",
            "--print",
            "after_move:filepath",
            "--progress-template",
            "download:%(progress._percent_str)s|%(progress.speed)s|%(progress.eta)s",
            "-o",
            outputTemplate,
            "-P",
            request.outputDirectory
        ]
        
        if let limit = request.options.speedLimitMBps {
            arguments.append(contentsOf: ["--limit-rate", "\(limit)M"])
        }

        appendNetworkContextArguments(
            to: &arguments,
            options: request.options,
            sourceURL: request.sourceURL
        )
        let formatPlan = buildFormatExpression(
            request: request,
            toolchain: toolchain
        )
        arguments.append(contentsOf: ["-f", formatPlan.expression])
        if request.options.audioOnly {
            arguments.append(contentsOf: ["-x", "--audio-format", "m4a"])
        } else if formatPlan.expectsMergedAudio {
            arguments.append(contentsOf: ["--merge-output-format", "mp4"])
        }

        if request.options.embedSubtitles {
            arguments.append(contentsOf: ["--write-subs", "--write-auto-subs", "--embed-subs"])
        }

        if request.options.writeMetadata {
            arguments.append(contentsOf: ["--write-info-json", "--write-thumbnail"])
        }

        if request.options.useAria2, toolchain.aria2cPath != nil {
            let connections = max(1, min(32, request.options.aria2Connections))
            let minSplit = max(1, min(16, request.options.aria2MinSplitSizeMB))
            let timeout = max(5, min(120, request.options.aria2TimeoutSeconds))
            
            var ariaArgs = [
                "--min-split-size=\(minSplit)M",
                "--max-connection-per-server=\(connections)",
                "--split=\(connections)",
                "--bt-stop-timeout=\(timeout)"
            ]
            
            if let limit = request.options.speedLimitMBps {
                ariaArgs.append("--max-overall-download-limit=\(limit)M")
            }
            
            arguments.append(contentsOf: [
                "--downloader", "aria2c",
                "--downloader-args", "aria2c:\(ariaArgs.joined(separator: " "))"
            ])
        }

        if let ffmpegPath = toolchain.ffmpegPath {
            arguments.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
        }

        if let infoJsonPath = resolveLocalInfoJsonPath(from: request.sourceURL) {
            arguments.append(contentsOf: ["--load-info-json", infoJsonPath])
        } else {
            arguments.append(normalizeSourceURL(request.sourceURL))
        }

        return DownloadArgumentsPlan(arguments: arguments, formatPlan: formatPlan)
    }

    func buildFormatExpression(request: DownloadRequest, toolchain: ToolchainStatus) -> FormatExpressionPlan {
        if let forcedExpression = request.forcedFormatExpression?.trimmingCharacters(in: .whitespacesAndNewlines),
           !forcedExpression.isEmpty {
            if toolchain.ffmpegPath == nil && forcedExpression.contains("+") {
                return FormatExpressionPlan(
                    expression: "best",
                    expectsMergedAudio: false,
                    downgradedToBestWithoutFFmpeg: true,
                    warningMessage: "ffmpeg is missing, so merged format fallback is disabled; using -f best."
                )
            }
            return FormatExpressionPlan(
                expression: forcedExpression,
                expectsMergedAudio: forcedExpression.contains("+"),
                downgradedToBestWithoutFFmpeg: false,
                warningMessage: nil
            )
        }

        let formatsByID = Dictionary(uniqueKeysWithValues: request.availableFormats.map { ($0.id, $0) })

        func validVideoID(_ value: String?) -> String? {
            guard let value,
                  !value.isEmpty,
                  value != FormatSelectionID.autoBestVideo,
                  formatsByID[value] != nil else {
                return nil
            }
            return value
        }

        func validAudioID(_ value: String?) -> String? {
            guard let value,
                  !value.isEmpty,
                  value != FormatSelectionID.autoBestAudio,
                  value != FormatSelectionID.noneAudio,
                  formatsByID[value] != nil else {
                return nil
            }
            return value
        }

        if request.options.audioOnly {
            let expression = validAudioID(request.selectedAudioFormatID) ?? "bestaudio/best"
            return FormatExpressionPlan(
                expression: expression,
                expectsMergedAudio: false,
                downgradedToBestWithoutFFmpeg: false,
                warningMessage: nil
            )
        }

        let explicitVideoID = validVideoID(request.selectedVideoFormatID)
        let videoExpression = explicitVideoID ?? "bestvideo*"

        let selectedAudio = request.selectedAudioFormatID ?? FormatSelectionID.autoBestAudio
        let audioExpression: String?
        if selectedAudio == FormatSelectionID.noneAudio {
            audioExpression = nil
        } else {
            audioExpression = validAudioID(request.selectedAudioFormatID) ?? "bestaudio"
        }

        if audioExpression == nil {
            if let explicitVideoID,
               let format = formatsByID[explicitVideoID],
               format.hasVideo && format.hasAudio {
                return FormatExpressionPlan(
                    expression: explicitVideoID,
                    expectsMergedAudio: false,
                    downgradedToBestWithoutFFmpeg: false,
                    warningMessage: nil
                )
            }
            return FormatExpressionPlan(
                expression: "\(videoExpression)/best",
                expectsMergedAudio: false,
                downgradedToBestWithoutFFmpeg: false,
                warningMessage: nil
            )
        }

        if toolchain.ffmpegPath == nil {
            return FormatExpressionPlan(
                expression: "best",
                expectsMergedAudio: false,
                downgradedToBestWithoutFFmpeg: true,
                warningMessage: "ffmpeg is missing; cannot merge video+audio streams, fallback to -f best."
            )
        }

        guard let audioExpression else {
            return FormatExpressionPlan(
                expression: "\(videoExpression)/best",
                expectsMergedAudio: false,
                downgradedToBestWithoutFFmpeg: false,
                warningMessage: nil
            )
        }

        return FormatExpressionPlan(
            expression: "\(videoExpression)+\(audioExpression)/best",
            expectsMergedAudio: true,
            downgradedToBestWithoutFFmpeg: false,
            warningMessage: nil
        )
    }

    private func appendNetworkContextArguments(
        to arguments: inout [String],
        options: DownloadOptions?,
        sourceURL: String
    ) {
        // Best-effort generic extractor impersonation path for anti-bot protected pages.
        arguments.append(contentsOf: ["--extractor-args", "generic:impersonate"])

        guard let options else {
            return
        }

        if let cookieBrowser = options.cookieSource.ytDlpValue {
            arguments.append(contentsOf: ["--cookies-from-browser", cookieBrowser])
        } else {
            let extracted = extractCookieHeader(from: options.customHeaders)
            if let cookieHeader = extracted.cookieHeader,
               let cookieFilePath = createTemporaryCookieFile(
                   cookieHeader: cookieHeader,
                   sourceURL: sourceURL
               ) {
                arguments.append(contentsOf: ["--cookies", cookieFilePath])
            }

            if !extracted.remainingHeaders.isEmpty {
                for header in extracted.remainingHeaders {
                    arguments.append(contentsOf: ["--add-header", header])
                }
            }
        }

        if !options.referer.isEmpty {
            arguments.append(contentsOf: ["--referer", options.referer])
        }

        if !options.userAgent.isEmpty {
            arguments.append(contentsOf: ["--user-agent", options.userAgent])
        }

    }

    private func extractCookieHeader(from headers: [String]) -> (cookieHeader: String?, remainingHeaders: [String]) {
        var cookieHeader: String?
        var remaining: [String] = []

        for header in headers {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else {
                remaining.append(trimmed)
                continue
            }

            let name = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.caseInsensitiveCompare("cookie") == .orderedSame {
                cookieHeader = value
            } else {
                remaining.append(trimmed)
            }
        }

        return (cookieHeader, remaining)
    }

    private func createTemporaryCookieFile(cookieHeader: String, sourceURL: String) -> String? {
        let pairs = cookieHeader
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { pair -> (String, String)? in
                guard let separator = pair.firstIndex(of: "=") else {
                    return nil
                }
                let name = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return nil
                }
                return (name, value)
            }

        guard !pairs.isEmpty,
              let url = URL(string: sourceURL),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RichVideoDownloader", isDirectory: true)
            .appendingPathComponent("cookies", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let cookieFile = tempDir.appendingPathComponent("cookies-\(UUID().uuidString).txt")
        let includeSubdomains = host.split(separator: ".").count > 1 ? "TRUE" : "FALSE"
        let secure = (url.scheme?.lowercased() == "https") ? "TRUE" : "FALSE"
        let expires = "2147483647"

        var lines = ["# Netscape HTTP Cookie File"]
        for (name, value) in pairs {
            lines.append("\(host)\t\(includeSubdomains)\t/\t\(secure)\t\(expires)\t\(name)\t\(value)")
        }

        do {
            try lines.joined(separator: "\n").write(to: cookieFile, atomically: true, encoding: .utf8)
            return cookieFile.path
        } catch {
            return nil
        }
    }

    private func normalizeSourceURL(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else {
            return rawValue
        }

        if var encodedQuery = components.percentEncodedQuery {
            encodedQuery = encodedQuery
                .replacingOccurrences(of: "{", with: "%7B")
                .replacingOccurrences(of: "}", with: "%7D")
                .replacingOccurrences(of: "\"", with: "%22")
                .replacingOccurrences(of: " ", with: "%20")
            components.percentEncodedQuery = encodedQuery
        }

        return components.string ?? rawValue
    }

    func resolveLocalInfoJsonPath(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let path: String
        if let url = URL(string: trimmed), url.isFileURL {
            path = url.path
        } else {
            path = trimmed
        }

        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        let lower = path.lowercased()
        if lower.hasSuffix(".info.json") || lower.hasSuffix(".json") {
            return path
        }

        return nil
    }

    private static func parseVideoInfo(data: Data, sourceURL: String) throws -> VideoInfo {
        guard let rootObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloaderServiceError.invalidMetadata
        }
        return try parseVideoInfo(rootObject: rootObject, sourceURLFallback: sourceURL)
    }

    private static func parseVideoInfo(rootObject: [String: Any], sourceURLFallback: String) throws -> VideoInfo {
        let resolvedSourceURL = (rootObject["webpage_url"] as? String)
            ?? (rootObject["original_url"] as? String)
            ?? sourceURLFallback

        let title = rootObject["title"] as? String ?? resolvedSourceURL
        let uploader = rootObject["uploader"] as? String
            ?? rootObject["channel"] as? String
            ?? rootObject["uploader_id"] as? String
        let durationSeconds = Self.readInt(rootObject["duration"])
        let thumbnailURL = rootObject["thumbnail"] as? String

        let rawFormats = rootObject["formats"] as? [[String: Any]] ?? []
        let formats = rawFormats
            .compactMap(Self.parseFormat)
            .sorted(by: Self.sortFormat)
        let muxedFormats = formats.filter { $0.hasVideo && $0.hasAudio }
        let videoOnlyFormats = formats.filter { $0.hasVideo && !$0.hasAudio }
        let audioOnlyFormats = formats.filter { !$0.hasVideo && $0.hasAudio }

        return VideoInfo(
            title: title,
            uploader: uploader,
            durationSeconds: durationSeconds,
            sourceURL: resolvedSourceURL,
            thumbnailURL: thumbnailURL,
            formats: formats,
            muxedFormats: muxedFormats,
            videoOnlyFormats: videoOnlyFormats,
            audioOnlyFormats: audioOnlyFormats
        )
    }

    func loadVideoInfo(fromJsonFile path: String) throws -> VideoInfo {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let rootObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloaderServiceError.invalidMetadata
        }
        return try Self.parseVideoInfo(rootObject: rootObject, sourceURLFallback: path)
    }

    private static func parseFormat(_ format: [String: Any]) -> VideoFormat? {
        guard let formatID = format["format_id"] as? String, !formatID.isEmpty else {
            return nil
        }

        let vcodec = (format["vcodec"] as? String) ?? "none"
        let acodec = (format["acodec"] as? String) ?? "none"
        let hasVideo = vcodec != "none"
        let hasAudio = acodec != "none"

        if !hasVideo, !hasAudio {
            return nil
        }

        let ext = (format["ext"] as? String ?? "bin").lowercased()
        let height = readInt(format["height"])
        let fps = readInt(format["fps"])
        let sizeBytes = readInt64(format["filesize"]) ?? readInt64(format["filesize_approx"])

        let resolutionPart: String = {
            if let height {
                return "\(height)p"
            }
            if let resolution = format["resolution"] as? String, !resolution.isEmpty {
                return resolution
            }
            if hasVideo {
                return "Video"
            }
            return "Audio"
        }()

        let codecPart: String = {
            switch (hasVideo, hasAudio) {
            case (true, true):
                return "Video+Audio"
            case (true, false):
                return "Video Only"
            case (false, true):
                return "Audio Only"
            case (false, false):
                return ""
            }
        }()

        let fpsPart = fps.map { "\($0)fps" }
        let sizePart = sizeBytes.map { formatBytes($0) }

        let labelParts = [
            formatID,
            resolutionPart,
            codecPart,
            ext.uppercased(),
            fpsPart,
            sizePart
        ].compactMap { value -> String? in
            guard let value else {
                return nil
            }
            return value.isEmpty ? nil : value
        }

        return VideoFormat(
            id: formatID,
            displayName: labelParts.joined(separator: " • "),
            ext: ext,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            height: height,
            sizeBytes: sizeBytes
        )
    }

    private static func sortFormat(lhs: VideoFormat, rhs: VideoFormat) -> Bool {
        func score(_ format: VideoFormat) -> Int {
            switch (format.hasVideo, format.hasAudio) {
            case (true, true):
                return 3
            case (true, false):
                return 2
            case (false, true):
                return 1
            case (false, false):
                return 0
            }
        }

        let lhsScore = score(lhs)
        let rhsScore = score(rhs)

        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        let lhsHeight = lhs.height ?? -1
        let rhsHeight = rhs.height ?? -1
        if lhsHeight != rhsHeight {
            return lhsHeight > rhsHeight
        }

        let lhsSize = lhs.sizeBytes ?? -1
        let rhsSize = rhs.sizeBytes ?? -1
        return lhsSize > rhsSize
    }

    private static func parseProgress(from line: String) -> DownloadProgressUpdate? {
        guard line.hasPrefix("download:") else {
            return nil
        }

        let payload = line.dropFirst("download:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = payload.split(
            separator: "|",
            maxSplits: 2,
            omittingEmptySubsequences: false
        ).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let percentage = parts.indices.contains(0)
            ? parts[0].replacingOccurrences(of: "%", with: "")
            : ""
        let fraction = Double(percentage).map { max(0.0, min(1.0, $0 / 100.0)) }

        let speedText = parts.indices.contains(1) ? normalizeMetric(parts[1]) : nil
        let etaText = parts.indices.contains(2) ? normalizeMetric(parts[2]) : nil

        return DownloadProgressUpdate(
            progressFraction: fraction,
            speedText: speedText,
            etaText: etaText
        )
    }

    private static func normalizeMetric(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "NA" || cleaned == "Unknown" {
            return nil
        }

        return cleaned
    }

    private static func readInt(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func readInt64(_ value: Any?) -> Int64? {
        switch value {
        case let int64Value as Int64:
            return int64Value
        case let intValue as Int:
            return Int64(intValue)
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }
}
