(function() {
  const contentRangeRegex = /^bytes (\d+)-(\d+)\/(\d+)$/;
  const CHUNK_SIZE = 1024 * 1024; // 1MB chunks
  const CONCURRENCY = 4; // Fetch 4 chunks at once
  
  const log = (msg) => {
    console.log("[RVD Main] " + msg);
    window.postMessage({ type: 'RVD_MAIN_LOG', message: msg }, '*');
  };

  log(`Bridge script parallelized (Concurrency: ${CONCURRENCY})`);

  window.addEventListener('message', async (event) => {
    if (event.data?.type !== 'RVD_MAIN_START_FETCH') return;
    
    const { url, id } = event.data;
    let totalSize = null;
    let nextOffset = 0;
    let activeWorkers = 0;
    let isError = false;

    log(`Starting parallel fetch for ${id}`);

    const fetchChunk = async (offset) => {
      try {
        const rangeEnd = totalSize ? Math.min(offset + CHUNK_SIZE - 1, totalSize - 1) : offset + CHUNK_SIZE - 1;
        const rangeHeader = `bytes=${offset}-${rangeEnd}`;
        
        const res = await fetch(url, { headers: { "Range": rangeHeader } });

        if (![200, 206].includes(res.status)) {
          throw new Error("Telegram status: " + res.status);
        }

        const rangeText = res.headers.get("Content-Range");
        const match = rangeText?.match(contentRangeRegex);
        if (match && totalSize === null) {
          totalSize = parseInt(match[3]);
        }
        
        let uint8;
        if (res.status === 206) {
          const buffer = await res.arrayBuffer();
          uint8 = new Uint8Array(buffer);
        } else {
          // Fallback if range is ignored (sequential only)
          log("WARN: Range ignored, falling back to sequential streaming...");
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
          for (let c of chunks) { uint8.set(c, pos); pos += c.length; }
        }

        const actualEnd = offset + uint8.byteLength - 1;
        const isFinish = (totalSize && actualEnd + 1 >= totalSize) || (res.status === 200 && uint8.length < CHUNK_SIZE);

        window.postMessage({
          type: 'RVD_MAIN_CHUNK',
          id: id,
          chunk: uint8, 
          offset: offset,
          progress: totalSize ? (actualEnd + 1) / totalSize : 0,
          isFinish: isFinish
        }, '*');

        if (isFinish) {
          log(`Finished successfully for ${id}`);
        }
      } catch (err) {
          if (!isError) {
            isError = true;
            log(`ERROR: ${err.message}`);
            window.postMessage({ type: 'RVD_MAIN_ERROR', id, message: err.message }, '*');
          }
      }
    };

    const runWorker = async () => {
      activeWorkers++;
      while (!isError) {
        let currentOffset;
        
        // Grab next chunk offset
        if (totalSize !== null && nextOffset >= totalSize) break;
        
        currentOffset = nextOffset;
        nextOffset += CHUNK_SIZE;
        
        await fetchChunk(currentOffset);
        
        // If we didn't know the size yet, we need to wait for the first chunk to finish
        // to establish the totalSize before workers can proceed safely.
        if (totalSize === null) break; 
      }
      activeWorkers--;
    };

    // Start workers
    // First worker to get the total size
    await runWorker();
    
    // Then start remaining workers
    if (totalSize !== null) {
       for (let i = 1; i < CONCURRENCY; i++) {
         runWorker();
       }
    }
  });
})();
