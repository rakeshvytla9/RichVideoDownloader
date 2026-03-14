import AppKit
import Combine
import Foundation

@MainActor
final class DownloaderViewModel: ObservableObject {
    private enum DownloadEngine {
        case ytDlp
        case dashMpd
        case telegramExtension
    }
    @Published var sourceURL: String = ""
    @Published var customFileName: String = ""
    @Published var outputDirectory: String = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
    }()

    @Published var discoveredInfo: VideoInfo?
    @Published var selectedVideoFormatID: String? = FormatSelectionID.autoBestVideo
    @Published var selectedAudioFormatID: String? = FormatSelectionID.autoBestAudio

    @Published var toolchain: ToolchainStatus = .init()
    @Published var isAnalyzing = false
    @Published var analysisError: String?

    @Published var queue: [DownloadItem] = []
    @Published var logs: [String] = []
    @Published var captureBridgeStatus: String = "Starting..."
    @Published var capturedMedia: [CapturedMediaItem] = []

    @Published var isQueueRunning = false
    @Published var maxConcurrentDownloads: Int = 2 {
        didSet {
            maxConcurrentDownloads = max(1, min(5, maxConcurrentDownloads))
            startQueuedDownloadsIfNeeded()
        }
    }

    @Published var defaultAudioOnly = false {
        didSet {
            resetSelectionDefaultsForCurrentMode()
        }
    }
    @Published var defaultEmbedSubtitles = false
    @Published var defaultWriteMetadata = true
    @Published var useAria2 = true
    @Published var cookieSource: BrowserCookieSource = .none
    @Published var refererHeader: String = ""
    @Published var userAgentHeader: String = ""
    @Published var customHeadersText: String = ""
    @Published var aria2Connections = 16 {
        didSet { aria2Connections = max(1, min(32, aria2Connections)) }
    }
    @Published var aria2MinSplitSizeMB = 1 {
        didSet { aria2MinSplitSizeMB = max(1, min(16, aria2MinSplitSizeMB)) }
    }
    @Published var aria2TimeoutSeconds = 30 {
        didSet { aria2TimeoutSeconds = max(5, min(120, aria2TimeoutSeconds)) }
    }
    @Published var speedLimitMBps: Int = 0 // 0 means unlimited
    @Published var downloadsFolderAccessGranted: Bool = false

    // Schedule State
    @Published var isSchedulerEnabled: Bool = false {
        didSet {
            updateScheduler()
        }
    }
    @Published var scheduledStartTime: Date = Date() {
        didSet {
            updateScheduler()
        }
    }
    private var schedulerTimer: Timer?
    
    // Category State
    @Published var selectedCategory: DownloadCategory = .all
    
    var filteredQueue: [DownloadItem] {
        if selectedCategory == .all {
            return queue
        }
        return queue.filter { $0.category == selectedCategory }
    }

    private let toolchainService = ToolchainService()
    private let ytDlpService = YtDlpService()
    private let dashMpdService = DashMpdService()
    private let captureBridgeServer = CaptureBridgeServer()
    private var activeDownloads: [UUID: ActiveDownloadProcess] = [:]
    private var downloadEngines: [UUID: DownloadEngine] = [:]
    private var downloadStartTimes: [UUID: Date] = [:]
    private var detectedOutputPaths: [UUID: URL] = [:]

    var queuedCount: Int {
        queue.filter { $0.state == .queued }.count
    }

    var runningCount: Int {
        queue.filter { $0.state == .downloading }.count
    }

    var canAnalyze: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnalyzing
    }

    var canQueueDirect: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canAddToQueue: Bool {
        discoveredInfo != nil
    }

    var shouldWarnSilentVideoSelection: Bool {
        guard !defaultAudioOnly, selectedAudioFormatID == FormatSelectionID.noneAudio else {
            return false
        }
        guard let info = discoveredInfo else {
            return true
        }
        guard let selectedVideoFormatID, selectedVideoFormatID != FormatSelectionID.autoBestVideo else {
            return true
        }
        if let format = info.formats.first(where: { $0.id == selectedVideoFormatID }) {
            return !(format.hasVideo && format.hasAudio)
        }
        return true
    }

    func bootstrap() async {
        startCaptureBridge()
        await refreshToolchain()
    }

    func refreshToolchain() async {
        toolchain = toolchainService.detect()
        if toolchain.aria2cPath == nil {
            useAria2 = false
        }
        appendLog("Tool scan completed. \(toolchain.missingToolsSummary)")
    }

    func analyzeURL() async {
        let trimmedURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            analysisError = "Please paste a URL first."
            return
        }

        if let localInfoPath = ytDlpService.resolveLocalInfoJsonPath(from: trimmedURL) {
            isAnalyzing = true
            analysisError = nil
            discoveredInfo = nil
            appendLog("Loading info JSON: \(localInfoPath)")

            do {
                let info = try ytDlpService.loadVideoInfo(fromJsonFile: localInfoPath)
                discoveredInfo = info
                customFileName = sanitizeFileName(info.title)
                resetSelectionDefaultsForCurrentMode()
                appendLog("Loaded info JSON: \(info.title) (\(info.formats.count) formats)")
            } catch {
                analysisError = "Failed to parse info JSON: \(error.localizedDescription)"
                appendLog("Info JSON load failed: \(error.localizedDescription)")
            }

            isAnalyzing = false
            return
        }

        let isDashManifest = isDashManifestURL(trimmedURL)
        if toolchain.ytDlpPath == nil {
            if isDashManifest {
                let fallbackInfo = buildDirectInfo(urlString: trimmedURL)
                discoveredInfo = fallbackInfo
                customFileName = sanitizeFileName(fallbackInfo.title)
                resetSelectionDefaultsForCurrentMode()
                analysisError = "DASH manifest detected. Metadata extraction is limited without yt-dlp. You can still Add To Queue."
                appendLog("Analyze metadata fallback engaged for DASH manifest.")
            } else {
                analysisError = "yt-dlp is required. Install it and refresh tools."
            }
            return
        }

        isAnalyzing = true
        analysisError = nil
        discoveredInfo = nil
        appendLog("Analyzing URL: \(trimmedURL)")

        do {
            let info = try await ytDlpService.fetchVideoInfo(
                for: trimmedURL,
                toolchain: toolchain,
                options: currentDownloadOptions()
            )
            discoveredInfo = info
            customFileName = sanitizeFileName(info.title)
            resetSelectionDefaultsForCurrentMode()
            appendLog("Metadata loaded: \(info.title) (\(info.formats.count) formats)")
        } catch {
            switch error {
            case DownloaderServiceError.metadataTimeout,
                DownloaderServiceError.metadataFailed,
                DownloaderServiceError.invalidMetadata:
                let fallbackInfo = buildDirectInfo(urlString: trimmedURL)
                discoveredInfo = fallbackInfo
                customFileName = sanitizeFileName(fallbackInfo.title)
                resetSelectionDefaultsForCurrentMode()
                analysisError = "Analyze could not fetch metadata from this URL. You can still Add To Queue using fallback info."
                appendLog("Analyze metadata fallback engaged; direct queue metadata was generated.")
            default:
                analysisError = error.localizedDescription
                appendLog("Analyze failed: \(error.localizedDescription)")
            }
        }

        isAnalyzing = false
    }

    func addDiscoveredToQueue() {
        guard let info = discoveredInfo else {
            return
        }

        let options = currentDownloadOptions()

        let finalExt = inferredExtension(for: info, options: options)

        let item = DownloadItem(
            id: UUID(),
            sourceURL: info.sourceURL,
            title: resolvedQueueTitle(fallback: info.title),
            customFileName: resolvedCustomFileName(),
            selectedVideoFormatID: selectedVideoFormatID,
            selectedAudioFormatID: selectedAudioFormatID,
            availableFormats: info.formats,
            outputDirectory: outputDirectory,
            options: options,
            captureSource: info.captureSource,
            category: DownloadCategory.infer(from: finalExt)
        )

        queue.append(item)
        appendLog("Queued: \(item.title)")

        if isQueueRunning {
            startQueuedDownloadsIfNeeded()
        }
    }

    func queueDirectURL() {
        let trimmedURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            analysisError = "Please paste a URL first."
            return
        }

        let info = buildDirectInfo(urlString: trimmedURL)
        discoveredInfo = info
        if resolvedCustomFileName() == nil {
            customFileName = sanitizeFileName(info.title)
        }
        resetSelectionDefaultsForCurrentMode()
        analysisError = nil

        let finalExt = inferredExtension(for: info, options: currentDownloadOptions())
        
        let item = DownloadItem(
            id: UUID(),
            sourceURL: trimmedURL,
            title: resolvedQueueTitle(fallback: info.title),
            customFileName: resolvedCustomFileName(),
            selectedVideoFormatID: selectedVideoFormatID,
            selectedAudioFormatID: selectedAudioFormatID,
            availableFormats: info.formats,
            outputDirectory: outputDirectory,
            options: currentDownloadOptions(),
            captureSource: info.captureSource,
            category: DownloadCategory.infer(from: finalExt)
        )

        queue.append(item)
        appendLog("Direct URL queued: \(item.title)")

        if isQueueRunning {
            startQueuedDownloadsIfNeeded()
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: outputDirectory)

        if panel.runModal() == .OK, let folderURL = panel.url {
            outputDirectory = folderURL.path
        }
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: outputDirectory))
    }

    func pasteURLFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let value = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            analysisError = "Clipboard does not contain text."
            return
        }

        sourceURL = value
        analysisError = nil
    }

    func retryCaptureBridge() {
        captureBridgeServer.stop()
        startCaptureBridge()
    }

    func useCapturedMedia(_ item: CapturedMediaItem) {
        sourceURL = item.mediaURL
        customFileName = suggestedFileName(for: item) ?? customFileName
        if let pageURL = item.pageURL, !pageURL.isEmpty, refererHeader.isEmpty {
            refererHeader = pageURL
        }
        if let cookieHeader = item.cookieHeader, !cookieHeader.isEmpty {
            upsertCustomHeader(name: "Cookie", value: cookieHeader)
        }
        appendLog("Loaded captured URL into analyzer.")
    }

    func removeCapturedMedia(_ item: CapturedMediaItem) {
        capturedMedia.removeAll { $0.id == item.id }
    }

    func clearCapturedMedia() {
        guard !capturedMedia.isEmpty else {
            return
        }

        capturedMedia.removeAll()
        appendLog("Cleared captured requests.")
    }

    func toggleQueueRunning() {
        if isQueueRunning {
            pauseQueue()
        } else {
            startQueue()
        }
    }

    func startQueue() {
        isQueueRunning = true
        appendLog("Queue started.")
        startQueuedDownloadsIfNeeded()
    }

    func pauseQueue() {
        isQueueRunning = false
        appendLog("Queue paused.")

        let currentlyRunning = queue.filter { $0.state == .downloading }.map(\.id)
        for id in currentlyRunning {
            pause(id: id)
        }
    }

    func pause(id: UUID) {
        if let process = activeDownloads[id] {
            updateItem(id: id) { item in
                item.state = .paused
                item.statusText = "Paused by user"
                item.updatedAt = Date()
            }
            process.terminate()
            if downloadEngines[id] == .telegramExtension {
                captureBridgeServer.cancelTelegramDownload(id: id.uuidString)
            }
            appendLog("Paused: \(titleFor(id: id))")
            return
        }

        updateItem(id: id) { item in
            if item.state == .queued {
                item.state = .paused
                item.statusText = "Paused before start"
                item.updatedAt = Date()
            }
        }
    }

    func resume(id: UUID) {
        updateItem(id: id) { item in
            if item.state == .paused || item.state == .failed || item.state == .cancelled {
                item.state = .queued
                item.statusText = "Waiting in queue"
                item.updatedAt = Date()
            }
        }

        appendLog("Resumed: \(titleFor(id: id))")

        if isQueueRunning {
            startQueuedDownloadsIfNeeded()
        }
    }

    func cancel(id: UUID) {
        if let process = activeDownloads[id] {
            process.terminate()
        }
        
        if downloadEngines[id] == .telegramExtension {
            captureBridgeServer.cancelTelegramDownload(id: id.uuidString)
        }

        updateItem(id: id) { item in
            item.state = .cancelled
            item.statusText = "Cancelled"
            item.updatedAt = Date()
        }

        appendLog("Cancelled: \(titleFor(id: id))")
        startQueuedDownloadsIfNeeded()
    }

    func retry(id: UUID) {
        updateItem(id: id) { item in
            item.state = .queued
            item.progressFraction = 0
            item.speedText = ""
            item.etaText = ""
            item.statusText = "Waiting in queue"
            item.forcedFormatExpression = nil
            item.fallbackRetryCount = 0
            item.updatedAt = Date()
        }

        appendLog("Retry queued: \(titleFor(id: id))")

        if isQueueRunning {
            startQueuedDownloadsIfNeeded()
        }
    }

    func remove(id: UUID) {
        if let process = activeDownloads[id] {
            process.terminate()
            activeDownloads[id] = nil
        }
        if downloadEngines[id] == .telegramExtension {
            captureBridgeServer.cancelTelegramDownload(id: id.uuidString)
        }

        downloadStartTimes[id] = nil
        detectedOutputPaths[id] = nil
        queue.removeAll { $0.id == id }
    }

    func clearCompleted() {
        queue.removeAll { $0.state == .completed || $0.state == .cancelled }
    }

    func clearQueue() {
        guard !queue.isEmpty else {
            return
        }

        for process in activeDownloads.values {
            process.terminate()
        }
        activeDownloads.removeAll()
        downloadEngines.removeAll()
        downloadStartTimes.removeAll()
        detectedOutputPaths.removeAll()
        queue.removeAll()
        appendLog("Removed all queue items.")
    }

    private func startQueuedDownloadsIfNeeded() {
        guard isQueueRunning else {
            return
        }

        while activeDownloads.count < maxConcurrentDownloads {
            guard let nextID = queue.first(where: { $0.state == .queued })?.id else {
                break
            }
            startDownload(id: nextID)
        }
    }

    private func startCaptureBridge() {
        captureBridgeServer.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.captureBridgeStatus = self?.normalizeBridgeStatus(status) ?? status
            }
        }

        captureBridgeServer.onCapture = { [weak self] payload in
            DispatchQueue.main.async {
                self?.handleCapturedPayload(payload)
            }
        }
        
        captureBridgeServer.onExtensionProgress = { [weak self] idStr, fraction in
            DispatchQueue.main.async {
                guard let id = UUID(uuidString: idStr) else { return }
                self?.updateItem(id: id) { item in
                    if item.state == .downloading {
                        item.progressFraction = max(item.progressFraction, fraction)
                        item.statusText = "Downloading via Browser"
                        item.updatedAt = Date()
                    }
                }
            }
        }
        
        captureBridgeServer.onExtensionFinish = { [weak self] idStr in
            DispatchQueue.main.async {
                guard let id = UUID(uuidString: idStr) else { return }
                self?.handleCompletion(id: id, exitCode: 0)
            }
        }
        
        captureBridgeServer.onExtensionError = { [weak self] idStr, message in
            DispatchQueue.main.async {
                guard let id = UUID(uuidString: idStr) else { return }
                self?.updateItem(id: id) { item in
                    item.state = .failed
                    item.statusText = "Browser extraction failed: \(message)"
                    item.updatedAt = Date()
                }
                self?.appendLog("Failed: \(message)")
                self?.activeDownloads[id] = nil
                self?.startQueuedDownloadsIfNeeded()
            }
        }

        captureBridgeServer.start()
    }

    private func normalizeBridgeStatus(_ status: String) -> String {
        let lowered = status.lowercased()
        if lowered.contains("error 48") || lowered.contains("address already in use") {
            return "Bridge failed: Port 38123 is already in use by another process. Close other RichVideoDownloader instances and click Retry Bridge."
        }
        return status
    }

    private func handleCapturedPayload(_ payload: CapturedRequestPayload) {
        appendLog("[Debug] Bridge received capture: \(payload.mediaURL)")
        guard !shouldIgnoreCapturedPayload(payload) else {
            return
        }

        let sourceTag = payload.captureSource ?? "unknown"
        let dedupeKey = "\(sourceTag)|\(payload.mediaURL)"
        let alreadyCaptured = capturedMedia.contains {
            "\($0.captureSource ?? "unknown")|\($0.mediaURL)" == dedupeKey
        }
        if alreadyCaptured {
            return
        }

        let item = CapturedMediaItem(
            id: UUID(),
            mediaURL: payload.mediaURL,
            pageURL: payload.pageURL,
            tabTitle: payload.tabTitle,
            resourceType: payload.resourceType,
            captureSource: payload.captureSource,
            fileName: payload.fileName,
            mimeType: payload.mimeType,
            cookieHeader: payload.cookieHeader,
            userAgent: payload.userAgent,
            capturedAt: Date()
        )

        capturedMedia.insert(item, at: 0)
        if capturedMedia.count > 40 {
            capturedMedia.removeLast(capturedMedia.count - 40)
        }

        if sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourceURL = payload.mediaURL
        }

        if let pageURL = payload.pageURL, !pageURL.isEmpty, refererHeader.isEmpty {
            refererHeader = pageURL
        }

        if let ua = payload.userAgent, !ua.isEmpty, userAgentHeader.isEmpty {
            userAgentHeader = ua
        }

        if let cookieHeader = payload.cookieHeader, !cookieHeader.isEmpty, customHeadersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upsertCustomHeader(name: "Cookie", value: cookieHeader)
        }

        if let fileName = payload.fileName, !fileName.isEmpty {
            appendLog("Captured \(sourceTag): \(fileName) -> \(payload.mediaURL)")
        } else {
            appendLog("Captured \(sourceTag): \(payload.mediaURL)")
        }
    }

    private func shouldIgnoreCapturedPayload(_ payload: CapturedRequestPayload) -> Bool {
        let urlExtension = URL(string: payload.mediaURL)?.pathExtension.lowercased()
        let fileExtension = payload.fileName?
            .split(separator: ".")
            .last
            .map(String.init)?
            .lowercased()

        return urlExtension == "m4s" || fileExtension == "m4s"
    }

    private func startDownload(id: UUID) {
        guard activeDownloads[id] == nil, let item = item(for: id) else {
            return
        }

        let isDashManifest = isDashManifestURL(item.sourceURL)
        let isTelegramStream = item.sourceURL.contains("/k/stream/") || item.captureSource == "telegram_injector" || item.sourceURL.contains("web.telegram.org")
        let shouldUseDash = isDashManifest && toolchain.dashMpdCliPath != nil
        if isDashManifest && toolchain.dashMpdCliPath == nil && toolchain.ytDlpPath == nil && !isTelegramStream {
            updateItem(id: id) { queuedItem in
                queuedItem.state = .failed
                queuedItem.statusText = "dash-mpd-cli or yt-dlp is required for DASH downloads"
                queuedItem.updatedAt = Date()
            }
            appendLog("Failed to start \(item.title): dash-mpd-cli and yt-dlp missing")
            return
        }

        if !shouldUseDash && toolchain.ytDlpPath == nil && !isTelegramStream {
            updateItem(id: id) { queuedItem in
                queuedItem.state = .failed
                queuedItem.statusText = "yt-dlp is not installed"
                queuedItem.updatedAt = Date()
            }
            appendLog("Failed to start \(item.title): yt-dlp missing")
            return
        }

        let request = DownloadRequest(
            id: item.id,
            sourceURL: item.sourceURL,
            customFileName: item.customFileName,
            selectedVideoFormatID: item.selectedVideoFormatID,
            selectedAudioFormatID: item.selectedAudioFormatID,
            availableFormats: item.availableFormats,
            forcedFormatExpression: item.forcedFormatExpression,
            outputDirectory: item.outputDirectory,
            options: item.options,
            captureSource: item.captureSource
        )

        do {
            updateItem(id: id) { queuedItem in
                queuedItem.state = .downloading
                queuedItem.statusText = "Starting..."
                queuedItem.updatedAt = Date()
            }

            let engine: DownloadEngine = isTelegramStream ? .telegramExtension : (shouldUseDash ? .dashMpd : .ytDlp)
            if isDashManifest && !shouldUseDash && toolchain.ytDlpPath != nil {
                appendLog("dash-mpd-cli not detected; using yt-dlp for DASH manifest.")
            }
            let process: ActiveDownloadProcess?
            switch engine {
            case .telegramExtension:
                let fileName = request.customFileName ?? "telegram_video.mp4"
                let sanitizedName = sanitizeFileName(fileName)
                let outPath = URL(fileURLWithPath: request.outputDirectory).appendingPathComponent(sanitizedName).path
                print("[Bridge] COMMAND: Sending Telegram download for id=\(id.uuidString) to path=\(outPath)")
                appendLog("Initiating Telegram download: \(sanitizedName)")
                captureBridgeServer.sendTelegramCommand(url: request.sourceURL, id: id.uuidString, savePath: outPath)
                process = nil
            case .dashMpd:
                process = try dashMpdService.startDownload(
                    request: request,
                    toolchain: toolchain,
                    onLog: { [weak self] line in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            self.handleLogLine(id: id, line: line)
                        }
                    },
                    onProgress: { [weak self] progress in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            self.handleProgress(id: id, progress: progress)
                        }
                    }
                )
            case .ytDlp:
                process = try ytDlpService.startDownload(
                    request: request,
                    toolchain: toolchain,
                    onLog: { [weak self] line in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            self.handleLogLine(id: id, line: line)
                        }
                    },
                    onProgress: { [weak self] progress in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            self.handleProgress(id: id, progress: progress)
                        }
                    }
                )
            }

            if let activeProcess = process {
                activeDownloads[id] = activeProcess
                activeProcess.waitForExit { [weak self] exitCode in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.handleCompletion(id: id, exitCode: exitCode)
                    }
                }
            } else {
                // Extension download, active process mapping is handled manually or skipped
                // Just keep track of it so pause/cancel know it's "running"
                // Using a dummy process to satisfy the dictionary type safely.
                let dummyProcess = Process()
                activeDownloads[id] = ActiveDownloadProcess(process: dummyProcess, stdoutReader: LinePipeReader(fileHandle: FileHandle.nullDevice, onLine: {_ in}), stderrReader: LinePipeReader(fileHandle: FileHandle.nullDevice, onLine: {_ in}))
            }
            
            downloadEngines[id] = engine
            downloadStartTimes[id] = Date()
            detectedOutputPaths[id] = nil
            appendLog("Download started: \(item.title)")
        } catch {
            updateItem(id: id) { queuedItem in
                queuedItem.state = .failed
                queuedItem.statusText = error.localizedDescription
                queuedItem.updatedAt = Date()
            }
            appendLog("Failed to start \(item.title): \(error.localizedDescription)")
        }
    }

    private func handleProgress(id: UUID, progress: DownloadProgressUpdate) {
        updateItem(id: id) { item in
            guard item.state == .downloading else {
                return
            }

            if let fraction = progress.progressFraction {
                item.progressFraction = max(item.progressFraction, fraction)
            }

            if let speedText = progress.speedText {
                item.speedText = speedText
            }

            if let etaText = progress.etaText {
                item.etaText = etaText
            }

            item.statusText = "Downloading"
            item.updatedAt = Date()
        }
    }

    private func handleLogLine(id: UUID, line: String) {
        let title = titleFor(id: id)
        appendLog("[\(title)] \(line)")
        captureOutputPathIfPresent(id: id, line: line)

        let lowered = line.lowercased()
        if lowered.contains("cloudflare anti-bot challenge") {
            updateItem(id: id) { item in
                if item.state == .downloading {
                    item.statusText = "Cloudflare blocked request (check impersonation dependency)"
                    item.updatedAt = Date()
                }
            }
            appendLog("Hint: run '/opt/homebrew/bin/yt-dlp --list-impersonate-targets' and install curl-cffi if targets are unavailable.")
            return
        }

        if lowered.contains("fallback to -f best") {
            updateItem(id: id) { item in
                if item.state == .downloading {
                    item.statusText = "ffmpeg missing: using best fallback"
                    item.updatedAt = Date()
                }
            }
            return
        }

        if lowered.contains("error") {
            updateItem(id: id) { item in
                if item.state == .downloading {
                    item.statusText = line
                    item.updatedAt = Date()
                }
            }
        }
    }

    private func handleCompletion(id: UUID, exitCode: Int32) {
        activeDownloads[id] = nil
        let engine = downloadEngines[id] ?? .ytDlp

        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            startQueuedDownloadsIfNeeded()
            return
        }

        switch queue[index].state {
        case .paused, .cancelled:
            queue[index].updatedAt = Date()
        default:
            if exitCode == 0 {
                let itemSnapshot = queue[index]
                let shouldCheckAudio = shouldCheckAudioGuardrail(for: itemSnapshot, engine: engine)
                let startTime = downloadStartTimes[id] ?? itemSnapshot.updatedAt
                if shouldCheckAudio,
                   let mediaFile = detectOutputMediaFile(for: itemSnapshot, startedAt: startTime),
                   !outputHasAudio(mediaFile) {
                    if engine == .ytDlp && itemSnapshot.fallbackRetryCount < 1 {
                        queue[index].state = .queued
                        queue[index].progressFraction = 0
                        queue[index].speedText = ""
                        queue[index].etaText = ""
                        queue[index].statusText = "No audio detected, retrying with safe format fallback"
                        queue[index].forcedFormatExpression = "bestvideo*+bestaudio/best"
                        queue[index].fallbackRetryCount = itemSnapshot.fallbackRetryCount + 1
                        queue[index].updatedAt = Date()
                        appendLog("Audio stream missing for \(queue[index].title); retrying with bestvideo*+bestaudio/best.")
                    } else {
                        queue[index].state = .failed
                        queue[index].statusText = engine == .dashMpd
                            ? "Download finished without audio. Try audio-only or update headers/cookies."
                            : "Download finished without audio after retry. Check format/cookies/headers."
                        queue[index].updatedAt = Date()
                        if engine == .dashMpd {
                            appendLog("Failed: \(queue[index].title) finished without audio (DASH).")
                        } else {
                            appendLog("Failed: \(queue[index].title) finished without audio after retry.")
                        }
                    }
                } else {
                    queue[index].state = .completed
                    queue[index].progressFraction = 1.0
                    queue[index].statusText = "Finished"
                    queue[index].forcedFormatExpression = nil
                    queue[index].updatedAt = Date()
                    appendLog("Completed: \(queue[index].title)")
                }
            } else {
                queue[index].state = .failed
                if queue[index].statusText == "Starting..." || queue[index].statusText == "Downloading" {
                    queue[index].statusText = "Exited with code \(exitCode)"
                }
                queue[index].updatedAt = Date()
                appendLog("Failed: \(queue[index].title) (exit \(exitCode))")
            }
        }

        downloadStartTimes[id] = nil
        detectedOutputPaths[id] = nil
        downloadEngines[id] = nil
        startQueuedDownloadsIfNeeded()
    }

    private func updateItem(id: UUID, mutate: (inout DownloadItem) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&queue[index])
    }

    private func item(for id: UUID) -> DownloadItem? {
        queue.first { $0.id == id }
    }

    // MARK: - Scheduler
    
    private func updateScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        
        guard isSchedulerEnabled else { return }
        
        // If scheduled time is in the past, assume it means "next occurrence" tomorrow
        var targetTime = scheduledStartTime
        if targetTime <= Date() {
            targetTime = Calendar.current.date(byAdding: .day, value: 1, to: targetTime) ?? targetTime
        }
        
        let timeInterval = targetTime.timeIntervalSinceNow
        
        // Only schedule if it's actually in the future
        if timeInterval > 0 {
            appendLog("Scheduler: Downloads will start at \(targetTime.formatted(date: .omitted, time: .shortened))")
            schedulerTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.appendLog("Scheduler: Starting scheduled downloads!")
                    self?.resumeDownloads()
                }
            }
        }
    }
    
    func toggleScheduler() {
        isSchedulerEnabled.toggle()
    }

    func resumeDownloads() {
        let pausedIDs = queue
            .filter { $0.state == .paused }
            .map(\.id)

        for id in pausedIDs {
            resume(id: id)
        }

        if !isQueueRunning {
            startQueue()
        } else {
            startQueuedDownloadsIfNeeded()
        }
    }
    
    // MARK: - Queue Management
    
    private func titleFor(id: UUID) -> String {
        queue.first(where: { $0.id == id })?.title ?? id.uuidString
    }

    private func resetSelectionDefaultsForCurrentMode() {
        if defaultAudioOnly {
            selectedAudioFormatID = FormatSelectionID.autoBestAudio
            selectedVideoFormatID = FormatSelectionID.autoBestVideo
            return
        }
        if selectedVideoFormatID == nil {
            selectedVideoFormatID = FormatSelectionID.autoBestVideo
        }
        if selectedAudioFormatID == nil {
            selectedAudioFormatID = FormatSelectionID.autoBestAudio
        }
    }

    private func inferredExtension(for info: VideoInfo, options: DownloadOptions) -> String? {
        if options.audioOnly {
            if let selectedAudioFormatID,
               selectedAudioFormatID != FormatSelectionID.autoBestAudio,
               selectedAudioFormatID != FormatSelectionID.noneAudio,
               let format = info.formats.first(where: { $0.id == selectedAudioFormatID }) {
                return format.ext
            }
            return "m4a"
        }

        if let selectedVideoFormatID,
           selectedVideoFormatID != FormatSelectionID.autoBestVideo,
           let format = info.formats.first(where: { $0.id == selectedVideoFormatID }) {
            return format.ext
        }

        return URL(string: info.sourceURL)?.pathExtension
    }

    private func shouldCheckAudioGuardrail(for item: DownloadItem, engine: DownloadEngine) -> Bool {
        _ = engine
        guard !item.options.audioOnly else {
            return false
        }

        guard item.selectedAudioFormatID != FormatSelectionID.noneAudio else {
            return false
        }

        return true
    }

    private func captureOutputPathIfPresent(id: UUID, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return
        }

        let candidate = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: candidate.path) {
            detectedOutputPaths[id] = candidate
        }
    }

    private func detectOutputMediaFile(for item: DownloadItem, startedAt: Date) -> URL? {
        if let detected = detectedOutputPaths[item.id], FileManager.default.fileExists(atPath: detected.path) {
            return detected
        }

        let outputURL = URL(fileURLWithPath: item.outputDirectory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: outputURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            guard let modifiedAt = values.contentModificationDate else {
                continue
            }
            if modifiedAt < startedAt.addingTimeInterval(-2) {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ["json", "jpg", "jpeg", "png", "webp", "txt", "vtt", "srt", "ass", "lrc", "part", "ytdl"].contains(ext) {
                continue
            }
            candidates.append((fileURL, modifiedAt))
        }

        if candidates.isEmpty {
            return nil
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        return candidates[0].url
    }

    private func outputHasAudio(_ fileURL: URL) -> Bool {
        guard let ffprobePath = toolchain.ffprobePath else {
            appendLog("Skipping audio verification for \(fileURL.lastPathComponent): ffprobe not found.")
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            fileURL.path
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            appendLog("Audio verification skipped (ffprobe failed to run): \(error.localizedDescription)")
            return true
        }

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown ffprobe error"
            appendLog("Audio verification warning for \(fileURL.lastPathComponent): \(errorText)")
            return true
        }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }

    private func currentDownloadOptions() -> DownloadOptions {
        DownloadOptions(
            audioOnly: defaultAudioOnly,
            embedSubtitles: defaultEmbedSubtitles,
            writeMetadata: defaultWriteMetadata,
            useAria2: useAria2,
            aria2Connections: max(1, min(32, aria2Connections)),
            aria2MinSplitSizeMB: max(1, min(16, aria2MinSplitSizeMB)),
            aria2TimeoutSeconds: max(5, min(120, aria2TimeoutSeconds)),
            speedLimitMBps: speedLimitMBps > 0 ? speedLimitMBps : nil,
            cookieSource: cookieSource,
            referer: refererHeader.trimmingCharacters(in: .whitespacesAndNewlines),
            userAgent: userAgentHeader.trimmingCharacters(in: .whitespacesAndNewlines),
            customHeaders: parseCustomHeaders(from: customHeadersText)
        )
    }

    private func resolvedCustomFileName() -> String? {
        let trimmed = customFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return sanitizeFileName(trimmed)
    }

    private func resolvedQueueTitle(fallback: String) -> String {
        resolvedCustomFileName() ?? fallback
    }

    private func suggestedFileName(for item: CapturedMediaItem) -> String? {
        if let fileName = item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileName.isEmpty {
            return sanitizeFileName(fileName)
        }

        if let tabTitle = item.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabTitle.isEmpty,
           tabTitle.lowercased() != "telegram web" {
            return sanitizeFileName(tabTitle)
        }

        return nil
    }

    private func isDashManifestURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if FileManager.default.fileExists(atPath: trimmed) {
            return (trimmed as NSString).pathExtension.lowercased() == "mpd"
        }

        if let url = URL(string: trimmed) {
            let path = url.path.lowercased()
            if path.hasSuffix(".mpd") {
                return true
            }
            if url.pathExtension.lowercased() == "mpd" {
                return true
            }
        }

        return trimmed.lowercased().contains(".mpd")
    }

    private func buildDirectInfo(urlString: String) -> VideoInfo {
        var title = "Direct Download"
        
        if let url = URL(string: urlString) {
            // Handle Telegram Web K/Z stream URLs that contain JSON metadata
            if url.path.contains("/k/stream/") || url.path.contains("/stream/"),
               let lastPiece = urlString.components(separatedBy: "/").last?.removingPercentEncoding {
                print("[Bridge] Attempting to parse Telegram JSON from: \(lastPiece.prefix(100))...")
                if lastPiece.hasPrefix("{") && lastPiece.hasSuffix("}") {
                    if let data = lastPiece.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let fn = json["fileName"] as? String {
                            print("[Bridge] Successfully extracted Telegram filename: \(fn)")
                            title = fn
                        }
                    }
                } else {
                    print("[Bridge] URL piece did not look like JSON (prefix/suffix check failed)")
                }
            } else {
                let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                let titleCandidate = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !titleCandidate.isEmpty {
                    title = titleCandidate
                } else if let host = url.host, !host.isEmpty {
                    title = host
                }
            }
        }

        return VideoInfo(
            title: title,
            uploader: nil,
            durationSeconds: nil,
            sourceURL: urlString,
            thumbnailURL: nil,
            formats: [],
            muxedFormats: [],
            videoOnlyFormats: [],
            audioOnlyFormats: [],
            captureSource: capturedMedia.first(where: { $0.mediaURL == urlString })?.captureSource
        )
    }

    private func parseCustomHeaders(from rawValue: String) -> [String] {
        rawValue
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { header in
                guard let separator = header.firstIndex(of: ":") else {
                    return false
                }

                let key = header[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = header[header.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return !key.isEmpty && !value.isEmpty
            }
    }

    private func upsertCustomHeader(name: String, value: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedValue.isEmpty else {
            return
        }

        var lines = customHeadersText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var replaced = false
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare(trimmedName) == .orderedSame {
                lines[index] = "\(trimmedName): \(trimmedValue)"
                replaced = true
                break
            }
        }

        if !replaced {
            lines.append("\(trimmedName): \(trimmedValue)")
        }

        customHeadersText = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logs.append(line)

        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
    }
}
