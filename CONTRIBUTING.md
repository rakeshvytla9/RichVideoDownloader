# Contributing

Thanks for contributing to RichVideoDownloader.

## Scope

- Keep changes focused on non-DRM downloads and authorized-use workflows.
- Do not add features intended to bypass DRM, paywalls, login walls, or other access controls.
- Prefer composing proven external tools instead of rebuilding site extractors from scratch.

## Local setup

```bash
brew install yt-dlp aria2 ffmpeg
cargo install dash-mpd-cli
swift build
swift test
node --check Extensions/chrome/service_worker.js
```

`aria2`, `ffmpeg`, and `dash-mpd-cli` are optional for some flows, but running with them installed gives the most complete local test surface.

## Pull request expectations

- Keep pull requests focused. Large mixed refactors are harder to review.
- Add or update tests when changing format selection, queue behavior, or download argument generation.
- If you change browser capture behavior, validate the extension worker with `node --check`.
- Update [README.md](README.md) when setup steps, feature scope, or tooling requirements change.

## Code style

- Follow the existing SwiftUI and service patterns in the repo.
- Prefer small services and testable logic over pushing more behavior into the main view model.
- Keep comments brief and only where they save real reader time.

## Reporting bugs

Include:

- The source URL type involved: direct media URL, webpage URL, `.mpd`, or browser-captured request
- Active options: cookies source, custom headers, referer, user-agent, audio-only, subtitles
- The relevant log lines from the app
- Whether the same URL works directly in `yt-dlp` or `dash-mpd-cli`
