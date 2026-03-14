(function() {
  const contentRangeRegex = /^bytes (\d+)-(\d+)\/(\d+)$/;
  const CHUNK_SIZE = 1024 * 1024; // 1MB chunks
  
  const log = (msg) => {
    console.log("[RVD Main] " + msg);
    window.postMessage({ type: 'RVD_MAIN_LOG', message: msg }, '*');
  };

  log("Bridge script initialized.");

  window.addEventListener('message', async (event) => {
    if (event.data?.type !== 'RVD_MAIN_START_FETCH') return;
    
    const { url, id } = event.data;
    let nextOffset = 0;
    let totalSize = null;

    log(`Starting streaming fetch for ${id}`);

    const fetchNext = async () => {
      try {
        const rangeEnd = totalSize ? Math.min(nextOffset + CHUNK_SIZE - 1, totalSize - 1) : nextOffset + CHUNK_SIZE - 1;
        const rangeHeader = `bytes=${nextOffset}-${rangeEnd}`;
        
        const res = await fetch(url, {
          headers: { "Range": rangeHeader }
        });

        if (![200, 206].includes(res.status)) {
          throw new Error("Telegram status: " + res.status);
        }

        const rangeText = res.headers.get("Content-Range");
        const contentLength = res.headers.get("Content-Length");
        const match = rangeText?.match(contentRangeRegex);
        
        
        if (match) {
          totalSize = parseInt(match[3]);
        }
        
        let uint8;
        if (res.status === 206) {
          const buffer = await res.arrayBuffer();
          uint8 = new Uint8Array(buffer);
        } else {
          log("WARN: Range ignored, streaming 1MB manually...");
          const reader = res.body.getReader();
          let chunks = [];
          let received = 0;
          while (true) {
            const { done, value } = await reader.read();
            if (done || !value) break;
            chunks.push(value);
            received += value.length;
            if (received >= CHUNK_SIZE) break;
          }
          await reader.cancel();
          
          uint8 = new Uint8Array(received);
          let pos = 0;
          for (let c of chunks) {
            uint8.set(c, pos);
            pos += c.length;
          }
        }

        const actualEnd = nextOffset + uint8.byteLength - 1;

        // Try to pass the buffer as a transferable to avoid clones if possible
        // but TypedArrays are fine too.
        window.postMessage({
          type: 'RVD_MAIN_CHUNK',
          id: id,
          chunk: uint8, 
          progress: totalSize ? (actualEnd + 1) / totalSize : 0,
          isFinish: (totalSize && actualEnd + 1 >= totalSize) || (res.status === 200 && uint8.length < CHUNK_SIZE)
        }, '*');

        nextOffset = actualEnd + 1;
        if (totalSize && nextOffset < totalSize) {
          setTimeout(fetchNext, 10);
        } else {
          log(`Finished successfully for ${id}`);
        }
      } catch (err) {
        log(`ERROR: ${err.message}`);
        window.postMessage({ type: 'RVD_MAIN_ERROR', id, message: err.message }, '*');
      }
    };

    fetchNext();
  });
})();
