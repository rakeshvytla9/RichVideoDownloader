# RichVideoDownloader (macOS SwiftUI)

**A premium, native macOS video downloader and manager.**

RichVideoDownloader is a high-performance, professional tool for capturing and organizing media from across the web. It combines the power of open-source toolchains (`yt-dlp`, `aria2`, `ffmpeg`) with a sleek, native macOS interface and a specialized browser extension for complex platforms like Telegram.

## 🎁 Standalone Distribution (One-Zip Setup)

The easiest way to get started is by using our **Self-Contained App Bundle**. This version requires **zero installation**—no Homebrew, Python, or external tools required.

1.  **Download**: Get the [RichVideoDownloader_Distribution.zip](https://github.com/rakeshvytla9/RichVideoDownloader/releases).
2.  **Move to Applications**: Drag `RichVideoDownloader.app` into your `/Applications` folder.
3.  **Install Extension**: 
    - Open Chrome (or any Chromium browser).
    - Go to `chrome://extensions` and enable **Developer Mode**.
    - Click **Load unpacked** and select the `ChromeExtension` folder inside the distribution zip.

## ✨ Key Features

- **🚀 100% Self-Contained**: All internal libraries (`.dylib`) and tools are bundled. It works out of the box on any Mac (macOS 14+).
- **💪 Parallel Downloads**: Use up to 32 connections per file for maximum bandwidth utilization.
- **📜 Session Persistence**: Your download history and settings are automatically saved and restored between launches.
- **✈️ Advanced Telegram Support**: Specialized bridge for capturing media from Telegram Web (WebK/WebZ), including Stories and restricted channels.
- **🎨 Premium macOS Design**: native SwiftUI interface with full-screen support, dark mode, and optimized window management.
- **🧠 Intelligent Queue**: IDM-style queue controls (Pause, Resume, Retry, Cancel) with configurable concurrency limits.
- **🔍 Metadata Rich**: Automatically fetches titles, thumbnails, and descriptions. Supports manual naming and automatic categorization (Video, Audio, Docs, etc.).

## 🏗️ Technical Architecture

This app follows a professional "Compose-Over-Reinvent" pattern:

- **Logic Layer**: SwiftUI + Swift 6.2 for a reactive, performant desktop experience.
- **Extraction Engine**: Standalone `yt-dlp` binary for robust site-specific parsing.
- **Transfer Engine**: `aria2c` for segmented, multi-connection downloads.
- **DASH Handling**: `dash-mpd-cli` for multi-stream manifest reconstruction.
- **Media Pipeline**: `ffmpeg` for muxing video/audio streams and post-processing.
- **Capture Bridge**: A local server (`127.0.0.1:38123`) that allows our browser extension to securely hand off authenticated media streams to the desktop app.

## 🛠️ Build from Source (Developers)

If you want to contribute or build the project yourself:

```bash
# Clone the repository
git clone https://github.com/rakeshvytla9/RichVideoDownloader.git
cd RichVideoDownloader

# Build and run
swift run
```

### 📦 Creating the Standalone Bundle
Use our custom packaging script to create the self-contained `.app`:
```bash
./package_app.sh
```
This script automates library bundling, rpath fixing, and companion folders preparation.

## ⚖️ Safety and Legal

Use this tool only for content you own or are authorized to download. Respect site terms, copyright law, and fair use guidelines.
