import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DownloaderViewModel()
    @State private var isSourceURLEditorPresented = false
    @State private var sourceURLEditDraft = ""

    var body: some View {
        NavigationSplitView {
            List(DownloadCategory.allCases, selection: $viewModel.selectedCategory) { category in
                NavigationLink(value: category) {
                    Label(category.rawValue, systemImage: icon(for: category))
                }
            }
            .navigationTitle("Categories")
            .frame(minWidth: 150)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerSection
                    toolchainSection
                    captureBridgeSection
                    analyzeSection

                    if let info = viewModel.discoveredInfo {
                        metadataSection(info)
                    }

                    queueControlsSection
                    queueListSection
                    logSection
                }
                .padding(16)
            }
            .frame(minWidth: 700, minHeight: 500)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await viewModel.bootstrap()
        }
        .sheet(isPresented: $isSourceURLEditorPresented) {
            sourceURLEditorSheet
        }
    }

    private func icon(for category: DownloadCategory) -> String {
        switch category {
        case .all: return "tray.full"
        case .video: return "film"
        case .audio: return "music.note"
        case .compressed: return "doc.zipper"
        case .documents: return "doc.text"
        case .programs: return "terminal"
        case .other: return "doc"
        }
    }

    private var headerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rich Video Downloader")
                    .font(.title2.weight(.semibold))
                Text("IDM-style queue manager for non-DRM streams using open-source engines: yt-dlp, aria2c, ffmpeg.")
                    .foregroundStyle(.secondary)
                Text("Chrome/Edge/Brave capture extension is included for one-click handoff from browser traffic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolchainSection: some View {
        GroupBox("Toolchain") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ToolStatusPill(name: "yt-dlp", path: viewModel.toolchain.ytDlpPath, required: true)
                    ToolStatusPill(name: "dash-mpd-cli", path: viewModel.toolchain.dashMpdCliPath, required: false)
                    ToolStatusPill(name: "aria2c", path: viewModel.toolchain.aria2cPath, required: false)
                    ToolStatusPill(name: "ffmpeg", path: viewModel.toolchain.ffmpegPath, required: false)
                    ToolStatusPill(name: "ffprobe", path: viewModel.toolchain.ffprobePath, required: false)
                }

                HStack(spacing: 10) {
                    Button("Refresh Tools") {
                        Task {
                            await viewModel.refreshToolchain()
                        }
                    }

                    Text(viewModel.toolchain.missingToolsSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Install command: brew install yt-dlp aria2 ffmpeg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var analyzeSection: some View {
        GroupBox("Analyze URL") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 8) {
                        TextField("Paste video URL", text: $viewModel.sourceURL)
                            .textFieldStyle(.plain)

                        Button {
                            sourceURLEditDraft = viewModel.sourceURL
                            isSourceURLEditorPresented = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit full URL")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                    Button("Paste") {
                        viewModel.pasteURLFromClipboard()
                    }

                    Button(viewModel.isAnalyzing ? "Analyzing..." : "Analyze") {
                        Task {
                            await viewModel.analyzeURL()
                        }
                    }
                    .disabled(!viewModel.canAnalyze)

                    Button("Queue Direct") {
                        viewModel.queueDirectURL()
                    }
                    .disabled(!viewModel.canQueueDirect)
                }

                HStack(spacing: 12) {
                    Text("Save As")
                        .frame(width: 55, alignment: .leading)

                    TextField("Rename output file", text: $viewModel.customFileName)
                        .textFieldStyle(.roundedBorder)

                    Text("This name is used for the queued title and saved file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.analysisError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                if !viewModel.canAddToQueue {
                    Text("Add To Queue appears after successful Analyze. Use Queue Direct to bypass metadata extraction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("Output")
                        .frame(width: 55, alignment: .leading)

                    Text(viewModel.outputDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.callout)

                    Spacer(minLength: 0)

                    Button("Choose") {
                        viewModel.chooseOutputDirectory()
                    }

                    Button("Open") {
                        viewModel.openOutputDirectory()
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Audio only", isOn: $viewModel.defaultAudioOnly)
                    Toggle("Embed subtitles", isOn: $viewModel.defaultEmbedSubtitles)
                    Toggle("Write metadata", isOn: $viewModel.defaultWriteMetadata)
                    Toggle("Use aria2 multi-connection", isOn: $viewModel.useAria2)
                        .disabled(viewModel.toolchain.aria2cPath == nil)

                    Spacer()

                    Stepper("Concurrent: \(viewModel.maxConcurrentDownloads)", value: $viewModel.maxConcurrentDownloads, in: 1...5)
                        .frame(width: 160)
                }

                if viewModel.useAria2 && viewModel.toolchain.aria2cPath != nil {
                    HStack(spacing: 24) {
                        HStack(spacing: 8) {
                            Text("Connections:")
                                .font(.callout)
                            Stepper("\(viewModel.aria2Connections)", value: $viewModel.aria2Connections, in: 1...32)
                                .fixedSize()
                        }
                        
                        HStack(spacing: 8) {
                            Text("Min split:")
                                .font(.callout)
                            Stepper("\(viewModel.aria2MinSplitSizeMB) MB", value: $viewModel.aria2MinSplitSizeMB, in: 1...16)
                                .fixedSize()
                        }
                        
                        HStack(spacing: 8) {
                            Text("Timeout:")
                                .font(.callout)
                            Stepper("\(viewModel.aria2TimeoutSeconds)s", value: $viewModel.aria2TimeoutSeconds, in: 5...120)
                                .fixedSize()
                        }
                        
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
                    Text("Global Speed Limit:")
                        .font(.callout)
                    Stepper(viewModel.speedLimitMBps == 0 ? "None" : "\(viewModel.speedLimitMBps) MB/s",
                            value: Binding(get: { viewModel.speedLimitMBps }, set: { viewModel.speedLimitMBps = max(0, min(1000, $0)) }),
                            in: 0...1000)
                        .fixedSize()
                        .font(.callout)
                    Spacer()
                }

                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Cookies:")
                            .font(.callout)
                        Picker("", selection: $viewModel.cookieSource) {
                            ForEach(BrowserCookieSource.allCases) { browser in
                                Text(browser.rawValue).tag(browser)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    TextField("Referer override (optional)", text: $viewModel.refererHeader)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("User-Agent override (optional)", text: $viewModel.userAgentHeader)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom headers (one per line, e.g. Authorization: Bearer ...)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.customHeadersText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureBridgeSection: some View {
        GroupBox("Browser Capture Bridge") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bridge: \(viewModel.captureBridgeStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Retry Bridge") {
                        viewModel.retryCaptureBridge()
                    }
                    .font(.caption)
                    if !viewModel.capturedMedia.isEmpty {
                        Button("Remove All", role: .destructive) {
                            viewModel.clearCapturedMedia()
                        }
                        .font(.caption)
                    }
                    Text("Use this if you see address-in-use errors.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Load Extensions/chrome, then browse normally. Media requests and browser downloads are captured here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.capturedMedia.isEmpty {
                    Text("No captured requests yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.capturedMedia) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) {
                                            if let captureSource = item.captureSource, !captureSource.isEmpty {
                                                Text(captureSource.replacingOccurrences(of: "_", with: " ").capitalized)
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let fileName = item.fileName, !fileName.isEmpty {
                                                Text(fileName)
                                                    .font(.caption2.weight(.semibold))
                                            }
                                        }
                                        if let tabTitle = item.tabTitle, !tabTitle.isEmpty {
                                            Text(tabTitle)
                                                .font(.caption.weight(.semibold))
                                        }
                                        Text(item.mediaURL)
                                            .font(.system(.caption2, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if let pageURL = item.pageURL, !pageURL.isEmpty {
                                            Text("Page: \(pageURL)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        if let mimeType = item.mimeType, !mimeType.isEmpty {
                                            Text("MIME: \(mimeType)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 8)

                                    Button("Use") {
                                        viewModel.useCapturedMedia(item)
                                    }
                                    Button("Analyze") {
                                        viewModel.useCapturedMedia(item)
                                        Task {
                                            await viewModel.analyzeURL()
                                        }
                                    }
                                    Button("Remove", role: .destructive) {
                                        viewModel.removeCapturedMedia(item)
                                    }
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                )
                            }
                        }
                    }
                    .frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataSection(_ info: VideoInfo) -> some View {
        GroupBox("Detected Media") {
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.headline)

                HStack(spacing: 14) {
                    if let uploader = info.uploader {
                        Text("Channel: \(uploader)")
                    }
                    Text("Duration: \(formatDuration(info.durationSeconds))")
                    Text("Formats: \(info.formats.count)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Picker(
                    "Video Format",
                    selection: Binding(
                        get: { viewModel.selectedVideoFormatID ?? FormatSelectionID.autoBestVideo },
                        set: { value in
                            viewModel.selectedVideoFormatID = value
                        }
                    )
                ) {
                    Text("Auto (Best Video)").tag(FormatSelectionID.autoBestVideo)
                    if !info.muxedFormats.isEmpty {
                        ForEach(info.muxedFormats) { format in
                            Text("Muxed: \(format.displayName)").tag(format.id)
                        }
                    }
                    if !info.videoOnlyFormats.isEmpty {
                        ForEach(info.videoOnlyFormats) { format in
                            Text("Video: \(format.displayName)").tag(format.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(viewModel.defaultAudioOnly)

                Picker(
                    "Audio Format",
                    selection: Binding(
                        get: { viewModel.selectedAudioFormatID ?? FormatSelectionID.autoBestAudio },
                        set: { value in
                            viewModel.selectedAudioFormatID = value
                        }
                    )
                ) {
                    Text("Auto (Best Audio)").tag(FormatSelectionID.autoBestAudio)
                    if !viewModel.defaultAudioOnly {
                        Text("None (Video Only)").tag(FormatSelectionID.noneAudio)
                    }
                    if !info.audioOnlyFormats.isEmpty {
                        ForEach(info.audioOnlyFormats) { format in
                            Text("Audio: \(format.displayName)").tag(format.id)
                        }
                    }
                }
                .pickerStyle(.menu)

                if viewModel.shouldWarnSilentVideoSelection {
                    Text("Warning: this selection can produce video without audio.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Add To Queue") {
                        viewModel.addDiscoveredToQueue()
                    }
                    .disabled(!viewModel.canAddToQueue)

                    Spacer()

                    if let selectedVideoFormatID = viewModel.selectedVideoFormatID {
                        Text("Video: \(selectedVideoFormatID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let selectedAudioFormatID = viewModel.selectedAudioFormatID {
                        Text("Audio: \(selectedAudioFormatID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queueControlsSection: some View {
        GroupBox("Queue") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(viewModel.isQueueRunning ? "Pause Queue" : "Start Queue") {
                        viewModel.toggleQueueRunning()
                    }
                    .disabled(viewModel.queue.isEmpty)

                    Button("Clear Completed") {
                        viewModel.clearCompleted()
                    }

                    Button("Remove All", role: .destructive) {
                        viewModel.clearQueue()
                    }
                    .disabled(viewModel.queue.isEmpty)

                    Spacer()

                    Text("Queued: \(viewModel.queuedCount)")
                    Text("Running: \(viewModel.runningCount)")
                    Text("Total: \(viewModel.queue.count)")
                }
                
                Divider()
                
                HStack {
                    Toggle("Enable Scheduler", isOn: $viewModel.isSchedulerEnabled)
                    
                    if viewModel.isSchedulerEnabled {
                        DatePicker(
                            "Start Time:",
                            selection: $viewModel.scheduledStartTime,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .frame(maxWidth: 300)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queueListSection: some View {
        GroupBox {
            if viewModel.filteredQueue.isEmpty {
                ContentUnavailableView(
                    "Queue is empty",
                    systemImage: "tray",
                    description: Text("Analyze a URL and add it to the queue.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.filteredQueue) { item in
                            DownloadRow(
                                item: item,
                                onPause: { viewModel.pause(id: item.id) },
                                onResume: { viewModel.resume(id: item.id) },
                                onCancel: { viewModel.cancel(id: item.id) },
                                onRetry: { viewModel.retry(id: item.id) },
                                onRemove: { viewModel.remove(id: item.id) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 240)
            }
        }
    }

    private var logSection: some View {
        GroupBox("Activity Log") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 150, maxHeight: 180)
        }
    }

    private var sourceURLEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit URL")
                .font(.headline)

            Text("Use this for long captured URLs, manifest links, or header-heavy links that are awkward to edit inline.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextEditor(text: $sourceURLEditDraft)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 760, minHeight: 240)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            HStack {
                Button("Cancel") {
                    isSourceURLEditorPresented = false
                }

                Spacer()

                Button("Apply") {
                    viewModel.sourceURL = sourceURLEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.analysisError = nil
                    isSourceURLEditorPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                stateBadge
            }

            Text(item.sourceURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: item.progressFraction)

            HStack(spacing: 12) {
                Text("\(Int(item.progressFraction * 100))%")
                Text(item.speedText.isEmpty ? "-" : item.speedText)
                Text(item.etaText.isEmpty ? "-" : "ETA: \(item.etaText)")
                Text(item.statusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                actionButtons
                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var stateBadge: some View {
        Text(item.state.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.18))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private var stateColor: Color {
        switch item.state {
        case .queued:
            return .blue
        case .downloading:
            return .green
        case .paused:
            return .orange
        case .completed:
            return .mint
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.state {
        case .downloading:
            Button("Pause", action: onPause)
            Button("Cancel", role: .destructive, action: onCancel)
        case .queued:
            Button("Pause", action: onPause)
            Button("Cancel", role: .destructive, action: onCancel)
        case .paused:
            Button("Resume", action: onResume)
            Button("Cancel", role: .destructive, action: onCancel)
        case .failed:
            Button("Retry", action: onRetry)
            Button("Remove", role: .destructive, action: onRemove)
        case .completed:
            Button("Remove", role: .destructive, action: onRemove)
        case .cancelled:
            Button("Retry", action: onRetry)
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

private struct ToolStatusPill: View {
    let name: String
    let path: String?
    let required: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(path == nil ? Color.red : Color.green)
                    .frame(width: 8, height: 8)

                Text(required ? "\(name) (required)" : "\(name) (optional)")
                    .font(.caption.weight(.semibold))
            }

            Text(path ?? "Not found")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}
