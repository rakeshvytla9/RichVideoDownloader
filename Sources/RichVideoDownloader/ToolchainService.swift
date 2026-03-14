import Foundation

struct ToolchainStatus {
    var ytDlpPath: String?
    var aria2cPath: String?
    var ffmpegPath: String?
    var ffprobePath: String?
    var dashMpdCliPath: String?

    var isReady: Bool {
        ytDlpPath != nil
    }

    var missingToolsSummary: String {
        var missing: [String] = []
        if ytDlpPath == nil {
            missing.append("yt-dlp")
        }
        if aria2cPath == nil {
            missing.append("aria2c (optional)")
        }
        if ffmpegPath == nil {
            missing.append("ffmpeg (recommended)")
        }
        if dashMpdCliPath == nil {
            missing.append("dash-mpd-cli (optional)")
        }

        if missing.isEmpty {
            return "All tools detected"
        }

        return "Missing: \(missing.joined(separator: ", "))"
    }
}

final class ToolchainService {
    private let fileManager = FileManager.default
    private var defaultSearchRoots: [String] {
        var roots = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/yt-dlp-venv/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        
        if let bundledBin = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            roots.insert(bundledBin, at: 0)
        }
        
        return roots
    }

    func detect() -> ToolchainStatus {
        let ytDlp = resolve(binary: "yt-dlp")
        let aria2c = resolve(binary: "aria2c")
        let ffmpeg = resolve(binary: "ffmpeg")
        let ffprobe = resolve(binary: "ffprobe")
        let dashMpdCli = resolve(binary: "dash-mpd-cli")

        return ToolchainStatus(
            ytDlpPath: ytDlp,
            aria2cPath: aria2c,
            ffmpegPath: ffmpeg,
            ffprobePath: ffprobe,
            dashMpdCliPath: dashMpdCli
        )
    }

    private func resolve(binary: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let searchRoots = defaultSearchRoots + pathEntries

        for root in searchRoots {
            let candidate = (root as NSString).appendingPathComponent(binary)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return resolveViaWhich(binary: binary)
    }

    private func resolveViaWhich(binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }

        return value
    }
}
