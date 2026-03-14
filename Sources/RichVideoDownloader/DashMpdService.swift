import Foundation

final class DashMpdService: @unchecked Sendable {
    private let fileManager = FileManager.default

    func startDownload(
        request: DownloadRequest,
        toolchain: ToolchainStatus,
        onLog: @escaping (String) -> Void,
        onProgress: @escaping (DownloadProgressUpdate) -> Void
    ) throws -> ActiveDownloadProcess {
        guard let dashMpdCliPath = toolchain.dashMpdCliPath else {
            throw DownloaderServiceError.missingRequiredTool("dash-mpd-cli")
        }

        let outputDirectory = URL(fileURLWithPath: request.outputDirectory)
        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        if request.options.embedSubtitles {
            onLog("Note: dash-mpd-cli does not embed subtitles; ignoring subtitle options.")
        }
        if request.options.writeMetadata {
            onLog("Note: dash-mpd-cli does not write metadata sidecars; ignoring metadata options.")
        }
        if request.options.useAria2 {
            onLog("Note: aria2 is not used for DASH downloads; ignoring aria2 settings.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dashMpdCliPath)
        process.currentDirectoryURL = outputDirectory
        process.arguments = buildDownloadArguments(request: request, toolchain: toolchain)

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

    private func buildDownloadArguments(request: DownloadRequest, toolchain: ToolchainStatus) -> [String] {
        var arguments: [String] = [
            "--no-version-check",
            "--progress",
            "json"
        ]

        if let limit = request.options.speedLimitMBps {
            arguments.append(contentsOf: ["--limit-rate", "\(limit)M"])
        }

        if let ffmpegPath = toolchain.ffmpegPath {
            arguments.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
        }

        appendNetworkContextArguments(to: &arguments, options: request.options)

        if request.options.audioOnly {
            arguments.append("--audio-only")
        } else if request.selectedAudioFormatID == FormatSelectionID.noneAudio {
            arguments.append("--video-only")
        }

        if let customFileName = request.customFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customFileName.isEmpty {
            let ext = request.options.audioOnly ? "m4a" : "mp4"
            let fileName = "\(sanitizeFileName(customFileName)).\(ext)"
            let outputPath = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
                .appendingPathComponent(fileName)
                .path
            arguments.append(contentsOf: ["--output", outputPath])
        }

        arguments.append(normalizedSourceArgument(request.sourceURL))
        return arguments
    }

    private func appendNetworkContextArguments(to arguments: inout [String], options: DownloadOptions) {
        if let cookieBrowser = options.cookieSource.ytDlpValue {
            arguments.append(contentsOf: ["--cookies-from-browser", cookieBrowser])
        }

        if !options.referer.isEmpty {
            arguments.append(contentsOf: ["--referer", options.referer])
        }

        if !options.userAgent.isEmpty {
            arguments.append(contentsOf: ["--user-agent", options.userAgent])
        }

        let headers = filteredHeaders(options.customHeaders, dropCookieHeader: options.cookieSource != .none)
        for header in headers {
            arguments.append(contentsOf: ["--add-header", header])
        }
    }

    private func filteredHeaders(_ headers: [String], dropCookieHeader: Bool) -> [String] {
        guard dropCookieHeader else {
            return headers
        }

        return headers.filter { header in
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.lowercased().hasPrefix("cookie:")
        }
    }

    private func normalizedSourceArgument(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return trimmed
        }

        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }

        if var encodedQuery = components.percentEncodedQuery {
            encodedQuery = encodedQuery
                .replacingOccurrences(of: "{", with: "%7B")
                .replacingOccurrences(of: "}", with: "%7D")
                .replacingOccurrences(of: "\"", with: "%22")
                .replacingOccurrences(of: " ", with: "%20")
            components.percentEncodedQuery = encodedQuery
        }

        return components.string ?? trimmed
    }

    private static func parseProgress(from line: String) -> DownloadProgressUpdate? {
        guard line.contains("\"type\"") else {
            return nil
        }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "progress" else {
            return nil
        }

        guard let percent = readDouble(json["percent"]) else {
            return nil
        }

        let bandwidth = readDouble(json["bandwidth"])
        let fraction = max(0.0, min(1.0, percent / 100.0))

        var speedText: String? = nil
        if let bandwidth, bandwidth > 0 {
            let clamped = min(bandwidth, Double(Int64.max))
            let formatted = formatBytes(Int64(clamped))
            if formatted != "Unknown" {
                speedText = "\(formatted)/s"
            }
        }

        return DownloadProgressUpdate(
            progressFraction: fraction,
            speedText: speedText,
            etaText: nil
        )
    }

    private static func readDouble(_ value: Any?) -> Double? {
        switch value {
        case let intValue as Int:
            return Double(intValue)
        case let int64Value as Int64:
            return Double(int64Value)
        case let doubleValue as Double:
            return doubleValue
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
}
