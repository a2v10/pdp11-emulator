import { IO_BASE, MEM_SIZE_BYTES, VEC_ODD } from './constants';
import { Memory } from './memory';
import { CpuTrap } from './trap';

/** A device mapped into the I/O page. Addresses are absolute, word-aligned. */
export interface Device {
  readonly name: string;
  readonly start: number; // first byte address (even)
  readonly end: number; // exclusive
  readWord(addr: number): number;
  writeWord(addr: number, value: number): void;
  reset?(): void;
}

/** Observer slot for the UI: fires on every memory/device access. */
export type AccessHook = (write: boolean, addr: number, value: number, byteWide: boolean) => void;

/**
 * The UNIBUS stand-in. Everything below IO_BASE is plain RAM (the
 * framebuffer is just RAM the display happens to look at); the I/O page
 * is dispatched to devices through a flat per-word lookup table.
 * Word access to an odd address or to a hole in the I/O page traps
 * through vector 4, like the real machine.
 */
export class Bus {
  readonly devices: Device[] = [];
  onAccess: AccessHook | null = null;
  private readonly ioMap: (Device | null)[];

  constructor(readonly memory: Memory) {
    this.ioMap = new Array((MEM_SIZE_BYTES - IO_BASE) >> 1).fill(null);
  }

  register(dev: Device): void {
    this.devices.push(dev);
    for (let a = dev.start; a < dev.end; a += 2) {
      this.ioMap[(a - IO_BASE) >> 1] = dev;
    }
  }

  resetDevices(): void {
    for (const dev of this.devices) dev.reset?.();
  }

  readWord(addr: number): number {
    if (addr & 1) throw new CpuTrap(VEC_ODD);
    const v = addr >= IO_BASE ? this.ioDevice(addr).readWord(addr) : this.memory.words[addr >> 1];
    if (this.onAccess !== null) this.onAccess(false, addr, v, false);
    return v;
  }

  writeWord(addr: number, value: number): void {
    if (addr & 1) throw new CpuTrap(VEC_ODD);
    value &= 0xffff;
    if (addr >= IO_BASE) this.ioDevice(addr).writeWord(addr, value);
    else this.memory.words[addr >> 1] = value;
    if (this.onAccess !== null) this.onAccess(true, addr, value, false);
  }

  readByte(addr: number): number {
    let v: number;
    if (addr >= IO_BASE) {
      const w = this.ioDevice(addr).readWord(addr & 0xfffe);
      v = addr & 1 ? (w >> 8) & 0xff : w & 0xff;
    } else {
      v = this.memory.bytes[addr];
    }
    if (this.onAccess !== null) this.onAccess(false, addr, v, true);
    return v;
  }

  writeByte(addr: number, value: number): void {
    value &= 0xff;
    if (addr >= IO_BASE) {
      // read-modify-write the device word
      const dev = this.ioDevice(addr);
      const even = addr & 0xfffe;
      const w = dev.readWord(even);
      dev.writeWord(even, addr & 1 ? (w & 0x00ff) | (value << 8) : (w & 0xff00) | value);
    } else {
      this.memory.bytes[addr] = value;
    }
    if (this.onAccess !== null) this.onAccess(true, addr, value, true);
  }

  private ioDevice(addr: number): Device {
    const dev = this.ioMap[(addr - IO_BASE) >> 1];
    if (dev === null) throw new CpuTrap(VEC_ODD); // bus timeout: nobody answered
    return dev;
  }
}
