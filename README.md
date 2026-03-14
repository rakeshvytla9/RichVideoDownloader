# RichVideoDownloader (macOS SwiftUI)

**A native macOS downloader with an IDM-style workflow.**

Built by composing proven open-source tools instead of rebuilding extraction/downloading internals. This project includes a specialized Chromium extension to handle complex streaming platforms like Telegram Web.

## 🚀 Quick Start (For New Users)

1.  **Install Requirements**: Open Terminal and run:
    ```bash
    brew install yt-dlp aria2 ffmpeg dash-mpd-cli
    ```
2.  **Download & Run**:
    ```bash
    git clone https://github.com/rakeshvytla9/RichVideoDownloader.git
    cd RichVideoDownloader
    swift run
    ```
3.  **Setup extension**: Load the `Extensions/chrome` folder into Chrome (via `chrome://extensions` -> Developer Mode -> Load Unpacked).

## Project Structure

- `Sources/`: Swift source code for the desktop application and local bridge server.
- `Extensions/chrome/`: Companion Chrome extension for main-world injection and streaming relay.

## Why this architecture

Industry tools usually combine:

- Browser capture / URL handoff
- Media extraction logic (site-specific)
- High-performance segmented transfer engine
- Post-processing/transcoding pipeline
- Queue/scheduler UX layer

This app follows that pattern:

- `yt-dlp`: media extraction + download orchestration
- `dash-mpd-cli`: DASH manifest downloads when `.mpd` sources are detected
- `aria2c`: segmented multi-connection transfers
- `ffmpeg`: muxing, remuxing, and media post-processing
- SwiftUI app: queue management, controls, and desktop UX

## Implemented features

- URL analysis with metadata extraction (title, uploader, duration, formats)
- Dual format selectors (Video + Audio) with automatic best fallback
- Audio-safe pairing logic:
  - Defaults to `bestvideo*+bestaudio/best` behavior in video mode
  - Prevents silent video by pairing audio unless user explicitly picks `Audio: None`
- Per-download options:
  - Audio-only extraction
  - Subtitle writing + embedding
  - Metadata/thumbnail sidecar files
  - Optional `aria2c` segmented mode
  - Segmentation tuning: connection count, min split size, timeout
  - Browser-session support for click-to-load pages:
    - `--cookies-from-browser` (Chrome/Safari/Firefox/Edge/Brave)
    - Referer and User-Agent override
    - Custom request headers
- IDM-style queue controls:
  - Add to queue
  - Start/Pause queue
  - Per-item Pause/Resume/Cancel/Retry/Remove
  - Concurrent download limit (1-5)
- Live progress telemetry:
  - Percentage
  - Speed
  - ETA
  - Status text
- Toolchain health panel with auto-detection and refresh
- Output folder picker + open-folder shortcut
- Timestamped activity log
- Local capture bridge (`http://127.0.0.1:38123`) for extension handoff
- Browser sniffer/interceptor extension (Chrome/Edge/Brave) under `Extensions/chrome`
  - Captures media requests via `webRequest`
  - Captures normal browser downloads via `downloads.onCreated`
  - Prompted takeover mode: asks per download (`Take over in app` vs `Keep in browser`)
- **Advanced Telegram Web Support**:
  - Bypasses strict security policies and 302 redirects via a "Split-World Bridge" (executing authorized fetches directly in the page context).
  - High-performance **Streaming Relay** for large media (700MB+), reading in 1MB chunks to prevent browser memory stalls.
  - Full support for restricted channels and Stories (WebK/WebZ).
  - Integrated Telegram-specific metadata extraction for original filenames.

## IDM-style parity notes

- Matches: queued downloads, pause/resume behavior, segmented backend support, per-item controls, progress telemetry, and browser sniffer handoff (Chrome/Edge/Brave).
- Planned next: Safari-native extension package.
- Not supported: DRM bypass or protected-stream circumvention.

## Requirements

- macOS 14+
- Xcode 16+ (or Swift 6.2 toolchain)
- Homebrew packages:

```bash
brew install yt-dlp aria2 ffmpeg dash-mpd-cli
```

`yt-dlp` is required for full metadata extraction and most sites. `aria2`, `ffmpeg`, and `dash-mpd-cli` are optional but highly recommended for full feature support.

## Build and run

```bash
cd RichVideoDownloader
swift build
swift test
swift run
```

You can also open the package directly in Xcode and run as a macOS app.

## Development

- Run `swift build` before opening a pull request.
- Run `swift test` for the Swift test suite.
- Run `node --check Extensions/chrome/service_worker.js` after touching the extension worker.
- Keep changes scoped to non-DRM workflows. Protected-stream bypass is out of scope for this repo.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the current workflow and expectations.

## Extension setup (network sniffer handoff)

1. Open `chrome://extensions` (or `edge://extensions` / `brave://extensions`).
2. Enable `Developer mode`.
3. Click `Load unpacked` and select `Extensions/chrome`.
4. If you previously loaded the extension, click `Reload` and accept the new `downloads`/`cookies`/`notifications` permissions.
5. Start the app (`swift run` or Xcode Run), then browse/play/download normally.
6. Captured media requests and browser downloads will appear in `Browser Capture Bridge`.

### Telegram Technical Notes
- **Main World Injection**: Unlike standard extensions that use an "Isolated World", this extension injects a bridge into the "Main World" of Telegram. This ensures that media fetches are seen as first-party requests and include the necessary session authorization to avoid the common `302` or `403` errors.
- **Streaming ReadableStream Relay**: Large videos are read using the `ReadableStream` API. This allows the extension to buffer exactly 1MB, send it to the app, and repeat, keeping the browser memory footprint low even for multi-gigabyte files.
- **Serialization Proxy**: Video binary data is converted to plain arrays during internal extension relay to ensure 100% data integrity across Chrome's messaging channels.

## Cloudflare 403 note

If logs show `Cloudflare anti-bot challenge`, verify impersonation support:

```bash
yt-dlp --list-impersonate-targets
```

If all targets show `unavailable`, install curl-cffi for the Python used by your `yt-dlp`.

## Safety and legal

Use this only for content you own or are authorized to download. Respect site terms and copyright law.
