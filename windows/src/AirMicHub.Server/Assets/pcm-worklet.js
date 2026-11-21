class PCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.chunkSize = Math.max(128, Math.round(sampleRate / 200)); // 5 ms
    this.buffer = new Float32Array(this.chunkSize);
    this.offset = 0;
    this.levelBlocks = 0;
    this.sumSquares = 0;
    this.sampleCount = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;
    const channel = input[0];

    for (let i = 0; i < channel.length; i++) {
      const sample = channel[i];
      this.buffer[this.offset++] = sample;
      this.sumSquares += sample * sample;
      this.sampleCount++;

      if (this.offset >= this.chunkSize) {
        const pcm = new Int16Array(this.chunkSize);
        for (let j = 0; j < this.chunkSize; j++) {
          const value = Math.max(-1, Math.min(1, this.buffer[j]));
          pcm[j] = value < 0 ? value * 0x8000 : value * 0x7fff;
        }
        this.port.postMessage({ type: "pcm", buffer: pcm.buffer }, [pcm.buffer]);
        this.offset = 0;
      }
    }

    this.levelBlocks++;
    if (this.levelBlocks >= 2) {
      const rms = Math.sqrt(this.sumSquares / Math.max(1, this.sampleCount));
      this.port.postMessage({ type: "level", value: rms * 2.2 });
      this.levelBlocks = 0;
      this.sumSquares = 0;
      this.sampleCount = 0;
    }
    return true;
  }
}

registerProcessor("pcm-processor", PCMProcessor);
