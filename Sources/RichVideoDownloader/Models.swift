import Foundation

enum FormatSelectionID {
    static let autoBestVideo = "AUTO_BEST_VIDEO"
    static let autoBestAudio = "AUTO_BEST_AUDIO"
    static let noneAudio = "NONE_AUDIO"
}

public enum DownloadState: String, Codable, Equatable, CaseIterable {
    case queued = "Queued"
    case downloading = "Downloading"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

public enum DownloadCategory: String, Codable, Equatable, CaseIterable, Identifiable {
    case all = "All"
    case video = "Video"
    case audio = "Audio"
    case compressed = "Compressed"
    case documents = "Documents"
    case programs = "Programs"
    case other = "Other"
    
    public var id: String { self.rawValue }
    
    public static func infer(from ext: String?) -> DownloadCategory {
        guard let ext = ext?.lowercased() else { return .other }
        switch ext {
        case "mp4", "mkv", "webm", "mov", "avi": return .video
        case "mp3", "m4a", "wav", "flac", "aac": return .audio
        case "zip", "rar", "7z", "tar", "gz": return .compressed
        case "pdf", "doc", "docx", "txt", "rtf", "xls", "xlsx", "csv": return .documents
        case "exe", "dmg", "pkg", "app", "sh", "bat": return .programs
        default: return .other
        }
    }
}

enum BrowserCookieSource: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case chrome = "Chrome"
    case safari = "Safari"
    case firefox = "Firefox"
    case edge = "Edge"
    case brave = "Brave"

    var id: String { rawValue }

    var ytDlpValue: String? {
        switch self {
        case .none:
            return nil
        case .chrome:
            return "chrome"
        case .safari:
            return "safari"
        case .firefox:
            return "firefox"
        case .edge:
            return "edge"
        case .brave:
            return "brave"
        }
    }
}

struct VideoFormat: Identifiable, Hashable {
    let id: String
    let displayName: String
    let ext: String
    let hasVideo: Bool
    let hasAudio: Bool
    let height: Int?
    let sizeBytes: Int64?
}

struct VideoInfo {
    let title: String
    let uploader: String?
    let durationSeconds: Int?
    let sourceURL: String
    let thumbnailURL: String?
    let formats: [VideoFormat]
    let muxedFormats: [VideoFormat]
    let videoOnlyFormats: [VideoFormat]
    let audioOnlyFormats: [VideoFormat]
    var captureSource: String? = nil
}

struct DownloadOptions: Hashable {
    var audioOnly: Bool
    var embedSubtitles: Bool
    var writeMetadata: Bool
    var useAria2: Bool
    var aria2Connections: Int
    var aria2MinSplitSizeMB: Int
    var aria2TimeoutSeconds: Int
    var speedLimitMBps: Int?

    var cookieSource: BrowserCookieSource
    var referer: String
    var userAgent: String
    var customHeaders: [String]
}

struct DownloadProgressUpdate {
    let progressFraction: Double?
    let speedText: String?
    let etaText: String?
}

struct DownloadItem: Identifiable, Hashable {
    let id: UUID
    let sourceURL: String
    var title: String
    var customFileName: String?
    var selectedVideoFormatID: String?
    var selectedAudioFormatID: String?
    var availableFormats: [VideoFormat]
    var forcedFormatExpression: String?
    var fallbackRetryCount: Int
    var outputDirectory: String
    var options: DownloadOptions
    var captureSource: String?

    var state: DownloadState
    var progressFraction: Double
    var speedText: String
    var etaText: String
    var statusText: String
    var category: DownloadCategory

    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: String,
        title: String,
        customFileName: String? = nil,
        selectedVideoFormatID: String? = FormatSelectionID.autoBestVideo,
        selectedAudioFormatID: String? = FormatSelectionID.autoBestAudio,
        availableFormats: [VideoFormat] = [],
        forcedFormatExpression: String? = nil,
        fallbackRetryCount: Int = 0,
        outputDirectory: String,
        options: DownloadOptions,
        captureSource: String? = nil,
        state: DownloadState = .queued,
        progressFraction: Double = 0.0,
        speedText: String = "",
        etaText: String = "",
        statusText: String = "Waiting in queue",
        category: DownloadCategory = .other,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.customFileName = customFileName
        self.selectedVideoFormatID = selectedVideoFormatID
        self.selectedAudioFormatID = selectedAudioFormatID
        self.availableFormats = availableFormats
        self.forcedFormatExpression = forcedFormatExpression
        self.fallbackRetryCount = fallbackRetryCount
        self.outputDirectory = outputDirectory
        self.options = options
        self.captureSource = captureSource
        self.state = state
        self.progressFraction = progressFraction
        self.speedText = speedText
        self.etaText = etaText
        self.statusText = statusText
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct DownloadRequest {
    let id: UUID
    let sourceURL: String
    let customFileName: String?
    let selectedVideoFormatID: String?
    let selectedAudioFormatID: String?
    let availableFormats: [VideoFormat]
    let forcedFormatExpression: String?
    let outputDirectory: String
    let options: DownloadOptions
    let captureSource: String?
}

func formatDuration(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "--" }

    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "Unknown" }

    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
}

func sanitizeFileName(_ rawValue: String) -> String {
    let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

    let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
        invalidCharacters.contains(scalar) ? "_" : Character(scalar)
    }
    let sanitized = String(sanitizedScalars)
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))

    return sanitized.isEmpty ? "download" : sanitized
}
