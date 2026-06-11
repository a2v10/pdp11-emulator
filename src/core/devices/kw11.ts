import type { Device } from '../bus';
import { KW11_LKS, VEC_CLOCK } from '../constants';

/**
 * KW11-L line time clock. The host calls tick() at 60 Hz; the clock sets
 * the monitor bit and, if interrupts are enabled, requests an interrupt
 * through vector 100 at priority 6. This is the game's "vsync".
 *
 * LKS register: bit 6 = interrupt enable (r/w), bit 7 = monitor flag
 * (set by the clock, cleared by writing).
 */
export class KW11 implements Device {
  readonly name = 'kw11';
  readonly start = KW11_LKS;
  readonly end = KW11_LKS + 2;
  lks = 0;

  constructor(private readonly irq: (vector: number, priority: number) => void) {}

  readWord(): number {
    return this.lks;
  }

  writeWord(_addr: number, value: number): void {
    this.lks = value & 0o300;
  }

  tick(): void {
    this.lks |= 0o200;
    if (this.lks & 0o100) this.irq(VEC_CLOCK, 6);
  }

  reset(): void {
    this.lks = 0;
  }
}
