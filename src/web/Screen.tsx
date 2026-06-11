import { useEffect, useRef } from 'react';
import { Machine } from '../core/machine';
import { FB_BASE, FB_BYTES, SCREEN_HEIGHT, SCREEN_WIDTH } from '../core/constants';

// RGBA little-endian (0xAABBGGRR): phosphor green on near-black
const ON = 0xff7aff5c;
const OFF = 0xff0c100c;

/** The display: reads the framebuffer once per frame and paints the canvas. */
export function Screen({ machine, frame }: { machine: Machine; frame: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const imgRef = useRef<ImageData | null>(null);

  useEffect(() => {
    const ctx = canvasRef.current?.getContext('2d');
    if (!ctx) return;
    if (!imgRef.current) imgRef.current = ctx.createImageData(SCREEN_WIDTH, SCREEN_HEIGHT);
    const img = imgRef.current;
    const px = new Uint32Array(img.data.buffer);
    const bytes = machine.memory.bytes;
    let di = 0;
    for (let a = FB_BASE; a < FB_BASE + FB_BYTES; a++) {
      const b = bytes[a];
      // bit 0 is the leftmost pixel of the byte
      px[di++] = b & 0x01 ? ON : OFF;
      px[di++] = b & 0x02 ? ON : OFF;
      px[di++] = b & 0x04 ? ON : OFF;
      px[di++] = b & 0x08 ? ON : OFF;
      px[di++] = b & 0x10 ? ON : OFF;
      px[di++] = b & 0x20 ? ON : OFF;
      px[di++] = b & 0x40 ? ON : OFF;
      px[di++] = b & 0x80 ? ON : OFF;
    }
    ctx.putImageData(img, 0, 0);
  }, [machine, frame]);

  return <canvas ref={canvasRef} width={SCREEN_WIDTH} height={SCREEN_HEIGHT} className="screen" />;
}
