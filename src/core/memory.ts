import { MEM_SIZE_BYTES } from './constants';

/**
 * 64 KB of byte-addressable RAM. Byte and word views share one buffer,
 * so word access is a single indexed read with no byte stitching.
 * PDP-11 is little-endian, and so is every platform JS engines run on.
 */
export class Memory {
  readonly buffer = new ArrayBuffer(MEM_SIZE_BYTES);
  readonly bytes = new Uint8Array(this.buffer);
  readonly words = new Uint16Array(this.buffer);
}
