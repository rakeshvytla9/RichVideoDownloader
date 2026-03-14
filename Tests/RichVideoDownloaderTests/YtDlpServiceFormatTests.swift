import Foundation
import XCTest
@testable import RichVideoDownloader

private func baseOptions(audioOnly: Bool = false) -> DownloadOptions {
    DownloadOptions(
        audioOnly: audioOnly,
        embedSubtitles: false,
        writeMetadata: false,
        useAria2: false,
        aria2Connections: 8,
        aria2MinSplitSizeMB: 1,
        aria2TimeoutSeconds: 30,
        speedLimitMBps: nil,
        cookieSource: .none,
        referer: "",
        userAgent: "",
        customHeaders: []
    )
}

private func sampleFormats() -> [VideoFormat] {
    [
        VideoFormat(id: "137", displayName: "137", ext: "mp4", hasVideo: true, hasAudio: false, height: 1080, sizeBytes: nil),
        VideoFormat(id: "140", displayName: "140", ext: "m4a", hasVideo: false, hasAudio: true, height: nil, sizeBytes: nil),
        VideoFormat(id: "22", displayName: "22", ext: "mp4", hasVideo: true, hasAudio: true, height: 720, sizeBytes: nil)
    ]
}

private func makeRequest(
    audioOnly: Bool = false,
    selectedVideo: String? = FormatSelectionID.autoBestVideo,
    selectedAudio: String? = FormatSelectionID.autoBestAudio,
    availableFormats: [VideoFormat]? = nil,
    forcedExpression: String? = nil
) -> DownloadRequest {
    DownloadRequest(
        id: UUID(),
        sourceURL: "https://example.com/video",
        customFileName: nil,
        selectedVideoFormatID: selectedVideo,
        selectedAudioFormatID: selectedAudio,
        availableFormats: availableFormats ?? sampleFormats(),
        forcedFormatExpression: forcedExpression,
        outputDirectory: "/tmp",
        options: baseOptions(audioOnly: audioOnly)
    )
}

private func toolchain(ffmpeg: String?) -> ToolchainStatus {
    ToolchainStatus(
        ytDlpPath: "/usr/bin/yt-dlp",
        aria2cPath: nil,
        ffmpegPath: ffmpeg,
        ffprobePath: nil,
        dashMpdCliPath: nil
    )
}

final class YtDlpServiceFormatTests: XCTestCase {
    func testAutoVideoAudioUsesBestPair() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(request: makeRequest(), toolchain: toolchain(ffmpeg: "/usr/bin/ffmpeg"))

        XCTAssertEqual(plan.expression, "bestvideo*+bestaudio/best")
        XCTAssertTrue(plan.expectsMergedAudio)
        XCTAssertFalse(plan.downgradedToBestWithoutFFmpeg)
    }

    func testExplicitVideoOnlyAutoPairsAudio() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(
            request: makeRequest(selectedVideo: "137", selectedAudio: FormatSelectionID.autoBestAudio),
            toolchain: toolchain(ffmpeg: "/usr/bin/ffmpeg")
        )

        XCTAssertEqual(plan.expression, "137+bestaudio/best")
        XCTAssertTrue(plan.expectsMergedAudio)
    }

    func testExplicitMuxedWithNoneAudioUsesMuxedID() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(
            request: makeRequest(selectedVideo: "22", selectedAudio: FormatSelectionID.noneAudio),
            toolchain: toolchain(ffmpeg: "/usr/bin/ffmpeg")
        )

        XCTAssertEqual(plan.expression, "22")
        XCTAssertFalse(plan.expectsMergedAudio)
    }

    func testAudioOnlyAutoUsesBestAudio() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(
            request: makeRequest(audioOnly: true, selectedVideo: nil, selectedAudio: FormatSelectionID.autoBestAudio),
            toolchain: toolchain(ffmpeg: "/usr/bin/ffmpeg")
        )

        XCTAssertEqual(plan.expression, "bestaudio/best")
        XCTAssertFalse(plan.expectsMergedAudio)
    }

    func testMissingFFmpegDowngradesPairToBest() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(
            request: makeRequest(selectedVideo: "137", selectedAudio: FormatSelectionID.autoBestAudio),
            toolchain: toolchain(ffmpeg: nil)
        )

        XCTAssertEqual(plan.expression, "best")
        XCTAssertFalse(plan.expectsMergedAudio)
        XCTAssertTrue(plan.downgradedToBestWithoutFFmpeg)
        XCTAssertNotNil(plan.warningMessage)
    }

    func testInvalidIDsFallbackToAutoPairing() {
        let service = YtDlpService()
        let plan = service.buildFormatExpression(
            request: makeRequest(selectedVideo: "invalid-video", selectedAudio: "invalid-audio"),
            toolchain: toolchain(ffmpeg: "/usr/bin/ffmpeg")
        )

        XCTAssertEqual(plan.expression, "bestvideo*+bestaudio/best")
        XCTAssertTrue(plan.expectsMergedAudio)
    }
}
