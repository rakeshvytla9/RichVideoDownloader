// Telegram Media Downloader Content Script
// Adapted from https://github.com/Neet-Nestor/Telegram-Media-Downloader

(function () {
  const logger = {
    info: (message, fileName = null) => {
      console.log(`[RVD Telegram Capture] ${fileName ? `${fileName}: ` : ""}${message}`);
    },
    error: (message, fileName = null) => {
      console.error(`[RVD Telegram Capture] ${fileName ? `${fileName}: ` : ""}${message}`);
    },
  };

  // Unicode values for icons (used in /k/ app)
  const DOWNLOAD_ICON = "\ue979";
  const FORWARD_ICON = "\ue99a";
  const REFRESH_DELAY = 500;

  const hashCode = (s) => {
    var h = 0,
      l = s.length,
      i = 0;
    if (l > 0) {
      while (i < l) {
        h = ((h << 5) - h + s.charCodeAt(i++)) | 0;
      }
    }
    return h >>> 0;
  };

  const captureMedia = (url, extension, isAudio = false) => {
    let fileName = hashCode(url).toString(36) + (extension ? `.${extension}` : (isAudio ? ".ogg" : ".mp4"));
    
    // Try to parse filename from Telegram stream URLs if possible
    try {
      const metadata = JSON.parse(decodeURIComponent(url.split("/")[url.split("/").length - 1]));
      if (metadata.fileName) {
        fileName = metadata.fileName;
      }
    } catch (e) {
      // Ignore
    }

    logger.info(`Capturing ${isAudio ? 'audio' : 'video'}: ${url}`, fileName);

    // Send to background script
    chrome.runtime.sendMessage({
      type: "CAPTURE_TELEGRAM_MEDIA",
      url: url,
      fileName: fileName
    });
  };

  const captureImage = (imageUrl) => {
    const fileName = (Math.random() + 1).toString(36).substring(2, 10) + ".jpeg";
    logger.info(`Capturing image: ${imageUrl}`, fileName);

    chrome.runtime.sendMessage({
      type: "CAPTURE_TELEGRAM_MEDIA",
      url: imageUrl,
      fileName: fileName
    }).catch(err => {
      logger.error("Failed to send image capture to background: " + err.message);
    });
  };

  // Keep track of auto-captured URLs to avoid spamming the app when scrolling
  const autoCapturedUrls = new Set();
  
  const autoCaptureVideo = (videoSrc) => {
    if (!videoSrc || autoCapturedUrls.has(videoSrc)) return;
    autoCapturedUrls.add(videoSrc);
    
    // Auto-capture only handles mp4s implicitly here
    captureMedia(videoSrc, "mp4", false);
  };

  logger.info("Initialized Telegram Media Downloader injector with Auto-Sniff");

  // --- For webz /a/ webapp ---
  setInterval(() => {
    // Stories
    const storiesContainer = document.getElementById("StoryViewer");
    if (storiesContainer) {
      const createDownloadButton = () => {
        const downloadIcon = document.createElement("i");
        downloadIcon.className = "icon icon-download";
        const downloadButton = document.createElement("button");
        downloadButton.className = "Button TkphaPyQ tiny translucent-white round tel-download rvd-injected";
        downloadButton.appendChild(downloadIcon);
        downloadButton.setAttribute("type", "button");
        downloadButton.setAttribute("title", "Capture to RVD");
        downloadButton.setAttribute("aria-label", "Capture to RVD");
        downloadButton.onclick = () => {
          const video = storiesContainer.querySelector("video");
          const videoSrc = video?.src || video?.currentSrc || video?.querySelector("source")?.src;
          if (videoSrc) {
            captureMedia(videoSrc, "mp4", false);
          } else {
            const images = storiesContainer.querySelectorAll("img.PVZ8TOWS");
            if (images.length > 0) {
              const imageSrc = images[images.length - 1]?.src;
              if (imageSrc) captureImage(imageSrc);
            }
          }
        };
        return downloadButton;
      };

      const storyHeader = storiesContainer.querySelector(".GrsJNw3y") || storiesContainer.querySelector(".DropdownMenu")?.parentNode;
      if (storyHeader && !storyHeader.querySelector(".rvd-injected")) {
        storyHeader.insertBefore(createDownloadButton(), storyHeader.querySelector("button"));
      }
    }

    // Media Viewer
    const mediaContainer = document.querySelector("#MediaViewer .MediaViewerSlide--active");
    const mediaViewerActions = document.querySelector("#MediaViewer .MediaViewerActions");
    if (!mediaContainer || !mediaViewerActions) return;

    const videoPlayer = mediaContainer.querySelector(".MediaViewerContent > .VideoPlayer");
    const img = mediaContainer.querySelector(".MediaViewerContent > div > img");
    
    const downloadIcon = document.createElement("i");
    downloadIcon.className = "icon icon-download";
    const downloadButton = document.createElement("button");
    downloadButton.className = "Button smaller translucent-white round tel-download rvd-injected";
    downloadButton.setAttribute("type", "button");
    downloadButton.setAttribute("title", "Capture to RVD");
    downloadButton.setAttribute("aria-label", "Capture to RVD");

    if (videoPlayer) {
      const video = videoPlayer.querySelector("video");
      if (!video) return;
      
      const videoUrl = video.currentSrc || video.src;
      if (!videoUrl) return;

      downloadButton.setAttribute("data-rvd-url", videoUrl);
      downloadButton.appendChild(downloadIcon);
      downloadButton.onclick = () => {
        captureMedia(videoUrl, "mp4", false);
      };

      const controls = videoPlayer.querySelector(".VideoPlayerControls");
      if (controls) {
        const buttons = controls.querySelector(".buttons");
        if (buttons && !buttons.querySelector("button.rvd-injected")) {
          const spacer = buttons.querySelector(".spacer");
          if (spacer) spacer.after(downloadButton.cloneNode(true));
        }
      }

      updateOrInjectTopbarButton(mediaViewerActions, downloadButton, videoUrl, () => captureMedia(videoPlayer.querySelector("video").currentSrc, "mp4", false));
      
      // Auto-capture the video
      autoCaptureVideo(videoUrl);
      
    } else if (img && img.src) {
      downloadButton.setAttribute("data-rvd-url", img.src);
      downloadButton.appendChild(downloadIcon);
      downloadButton.onclick = () => {
        captureImage(img.src);
      };

      updateOrInjectTopbarButton(mediaViewerActions, downloadButton, img.src, () => captureImage(img.src));
    }
  }, REFRESH_DELAY);

  const contentRangeRegex = /^bytes (\d+)-(\d+)\/(\d+)$/;

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "START_PROXY_DOWNLOAD" && message.command) {
      logger.info("Received download command from background script");
      startProxyDownload(message.command);
      sendResponse({ ack: true });
    }
    return true;
  });

  // --- MAIN WORLD RELAY ---
  // Commands and Chunks are relayed between the ISOLATED world (where this script lives)
  // and the MAIN world (where main_world_bridge.js lives via manifest.json).
  
  // Listen for chunks coming back from the MAIN world
  window.addEventListener('message', (event) => {
    if (event.data?.type === 'RVD_MAIN_CHUNK') {
      const { id, chunk, progress, isFinish } = event.data;
      chrome.runtime.sendMessage({
        type: "PROXY_CHUNK",
        id, 
        chunk: Array.from(chunk), // CRITICAL: Convert to plain Array to avoid serialization loss
        progress, 
        isFinish
      }).catch(() => {});
    } else if (event.data?.type === 'RVD_MAIN_LOG') {
      chrome.runtime.sendMessage({
        type: "PROXY_LOG",
        message: "[Page] " + event.data.message
      }).catch(() => {});
    } else if (event.data?.type === 'RVD_MAIN_ERROR') {
      const { id, message } = event.data;
      chrome.runtime.sendMessage({
        type: "PROXY_ERROR",
        id, message: "[MainWorld] " + message
      });
    }
  });

  async function startProxyDownload(command) {
    logger.info("Relaying download command to MAIN world bridge for " + command.id);
    window.postMessage({
      type: 'RVD_MAIN_START_FETCH',
      url: command.url,
      id: command.id
    }, '*');
  }

  function updateOrInjectTopbarButton(container, newButton, targetUrl, clickHandler) {
    const existingScriptButton = container.querySelector("button.tel-download:not(.rvd-injected)");
    if (existingScriptButton) {
      existingScriptButton.remove(); // Remove original userscript button if present
    }

    const existingRvdButton = container.querySelector("button.rvd-injected");
    if (existingRvdButton) {
      if (existingRvdButton.getAttribute("data-rvd-url") !== targetUrl) {
        existingRvdButton.onclick = clickHandler;
        existingRvdButton.setAttribute("data-rvd-url", targetUrl);
      }
    } else {
      newButton.onclick = clickHandler;
      container.prepend(newButton);
    }
  }


  // --- For webk /k/ webapp ---
  setInterval(() => {
    const pinnedAudio = document.body.querySelector(".pinned-audio");
    let dataMid;
    let downloadButtonPinnedAudio = document.body.querySelector("._rvd_button_pinned_container") || document.createElement("button");
    
    if (pinnedAudio) {
      dataMid = pinnedAudio.getAttribute("data-mid");
      downloadButtonPinnedAudio.className = "btn-icon tgico-download _rvd_button_pinned_container rvd-injected";
      downloadButtonPinnedAudio.innerHTML = `<span class="tgico button-icon">${DOWNLOAD_ICON}</span>`;
      downloadButtonPinnedAudio.setAttribute("title", "Capture to RVD");
    }

    const audioElements = document.body.querySelectorAll("audio-element");
    audioElements.forEach((audioElement) => {
      const bubble = audioElement.closest(".bubble");
      if (!bubble || bubble.querySelector("._rvd_button_pinned_container")) {
        return;
      }
      if (dataMid && downloadButtonPinnedAudio.getAttribute("data-mid") !== dataMid && audioElement.getAttribute("data-mid") === dataMid) {
        const link = audioElement.audio && audioElement.audio.getAttribute("src");
        const isAudio = audioElement.audio && audioElement.audio instanceof HTMLAudioElement;
        
        downloadButtonPinnedAudio.onclick = (e) => {
          e.stopPropagation();
          if (link) captureMedia(link, isAudio ? "ogg" : "mp4", isAudio);
        };
        downloadButtonPinnedAudio.setAttribute("data-mid", dataMid);
        
        if (link) {
          pinnedAudio.querySelector(".pinned-container-wrapper-utils")?.appendChild(downloadButtonPinnedAudio);
        }
      }
    });

    // Stories (webk)
    const storiesContainer = document.getElementById("stories-viewer");
    if (storiesContainer) {
      const createDownloadButton = () => {
        const downloadButton = document.createElement("button");
        downloadButton.className = "btn-icon rp tel-download rvd-injected";
        downloadButton.innerHTML = `<span class="tgico">${DOWNLOAD_ICON}</span><div class="c-ripple"></div>`;
        downloadButton.setAttribute("type", "button");
        downloadButton.setAttribute("title", "Capture to RVD");
        downloadButton.setAttribute("aria-label", "Capture to RVD");
        downloadButton.onclick = () => {
          const video = storiesContainer.querySelector("video.media-video");
          const videoSrc = video?.src || video?.currentSrc || video?.querySelector("source")?.src;
          if (videoSrc) {
            captureMedia(videoSrc, "mp4", false);
          } else {
            const imageSrc = storiesContainer.querySelector("img.media-photo")?.src;
            if (imageSrc) captureImage(imageSrc);
          }
        };
        return downloadButton;
      };

      const storyHeader = storiesContainer.querySelector("[class^='_ViewerStoryHeaderRight']");
      if (storyHeader && !storyHeader.querySelector(".rvd-injected")) {
        storyHeader.prepend(createDownloadButton());
      }

      const storyFooter = storiesContainer.querySelector("[class^='_ViewerStoryFooterRight']");
      if (storyFooter && !storyFooter.querySelector(".rvd-injected")) {
        storyFooter.prepend(createDownloadButton());
      }
    }

    // Media Viewer (webk)
    const mediaContainer = document.querySelector(".media-viewer-whole");
    if (!mediaContainer) return;

    const mediaAspecter = mediaContainer.querySelector(".media-viewer-movers .media-viewer-aspecter");
    const mediaButtons = mediaContainer.querySelector(".media-viewer-topbar .media-viewer-buttons");
    if (!mediaAspecter || !mediaButtons) return;

    // Unhide hidden buttons (standard behavior of original script)
    const hiddenButtons = mediaButtons.querySelectorAll("button.btn-icon.hide");
    for (const btn of hiddenButtons) {
      btn.classList.remove("hide");
      if (btn.textContent === FORWARD_ICON) {
        btn.classList.add("tgico-forward");
      }
      if (btn.textContent === DOWNLOAD_ICON) {
        btn.classList.add("tgico-download");
      }
    }

    // We take over the download button entirely if possible, or inject our own.
    const createWebkButton = (clickHandler) => {
      const b = document.createElement("button");
      b.className = "btn-icon tgico-download tel-download rvd-injected";
      b.innerHTML = `<span class="tgico button-icon">${DOWNLOAD_ICON}</span>`;
      b.setAttribute("type", "button");
      b.setAttribute("title", "Capture to RVD");
      b.onclick = clickHandler;
      return b;
    };

    if (mediaAspecter.querySelector(".ckin__player")) {
      const controls = mediaAspecter.querySelector(".default__controls.ckin__controls");
      if (controls && !controls.querySelector(".rvd-injected")) {
        const brControls = controls.querySelector(".bottom-controls .right-controls");
        if (brControls) {
           const downloadButton = document.createElement("button");
           downloadButton.className = "btn-icon default__button tgico-download tel-download rvd-injected";
           downloadButton.innerHTML = `<span class="tgico">${DOWNLOAD_ICON}</span>`;
           downloadButton.setAttribute("type", "button");
           downloadButton.setAttribute("title", "Capture to RVD");
           downloadButton.onclick = () => captureMedia(mediaAspecter.querySelector("video").src, "mp4", false);
           brControls.prepend(downloadButton);
        }
      }
    } else if (mediaAspecter.querySelector("video") && !mediaButtons.querySelector("button.rvd-injected")) {
      const videoSrc = mediaAspecter.querySelector("video").src;
      const btn = createWebkButton(() => captureMedia(videoSrc, "mp4", false));
      mediaButtons.prepend(btn);
      
      // Auto-capture the video
      autoCaptureVideo(videoSrc);
    } else if (!mediaButtons.querySelector("button.rvd-injected")) {
      const img = mediaAspecter.querySelector("img.thumbnail");
      if (img && img.src) {
        const btn = createWebkButton(() => captureImage(img.src));
        mediaButtons.prepend(btn);
      }
    }

    // Also hijack existing native download buttons to force RVD capture if present
    const nativeDownloadBtns = mediaButtons.querySelectorAll("button.tgico-download:not(.rvd-injected)");
    nativeDownloadBtns.forEach(btn => {
      btn.classList.add("rvd-injected");
      btn.setAttribute("title", "Capture to RVD");
      btn.onclick = (e) => {
          e.preventDefault();
          e.stopPropagation();
          const video = mediaAspecter.querySelector("video");
          const img = mediaAspecter.querySelector("img.thumbnail");
          if (video && (video.currentSrc || video.src)) captureMedia(video.currentSrc || video.src, "mp4", false);
          else if (img && img.src) captureImage(img.src);
      };
    });

    if (Math.random() < 0.05) {
       logger.info("Injector Heartbeat: Searching for media elements...");
    }

  }, REFRESH_DELAY);

})();
