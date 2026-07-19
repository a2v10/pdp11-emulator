import type { Device } from '../bus';
import { KW11P_CSB, KW11P_CNT, KW11P_CSR, VEC_PCLK } from '../constants';

// cycles per count at each rate: stopped, 100 kHz, 10 kHz, and the
// external input, which on this machine is wired to a 125 kHz crystal —
// 125000 / (2 * 142) = 440.14 Hz, so musical notes land on integer
// presets within a few cents
const RATE_CYCLES = [0, 10, 100, 8];

/**
 * KW11-P programmable real-time clock, the repeated-interval subset:
 * the counter runs down at the selected rate, and on reaching zero
 * reloads itself from the count-set buffer and (with IE) interrupts
 * through vector 104 at priority 6.
 *
 * CSR: bits 0-1 rate select, bit 6 interrupt enable, bit 7 done flag
 * (set on every expiry, cleared by writing the CSR). Writing the
 * count-set buffer does not disturb the running counter — the new
 * period takes over at the next reload, so a program may glide the
 * pitch without resetting the phase.
 */
export class KW11P implements Device {
  readonly name = 'kw11p';
  readonly start = KW11P_CSR;
  readonly end = KW11P_CNT + 2;
  csr = 0;
  preset = 0;
  /** Cycles until the next expiry; 0 = the clock is stopped. */
  rem = 0;

  constructor(private readonly irq: (vector: number, priority: number) => void) {}

  private get tick(): number {
    return RATE_CYCLES[this.csr & 3];
  }

  private period(): number {
    return (this.preset === 0 ? 0x10000 : this.preset) * this.tick;
  }

  readWord(addr: number): number {
    if (addr === KW11P_CSR) return this.csr;
    if (addr === KW11P_CSB) return this.preset;
    return this.tick > 0 ? Math.ceil(this.rem / this.tick) : 0;
  }

  writeWord(addr: number, value: number): void {
    if (addr === KW11P_CSR) {
      const was = this.tick;
      this.csr = value & 0o177; // writing clears the done flag
      const now = this.tick;
      if (now === 0) this.rem = 0;
      else if (was !== now) this.rem = this.period(); // (re)armed
    } else if (addr === KW11P_CSB) {
      this.preset = value;
    }
    // the counter register itself is read-only
  }

  /** Called with the cycles each instruction spent; fires expiries. */
  advance(cycles: number): void {
    if (this.rem === 0) return;
    this.rem -= cycles;
    while (this.rem <= 0) {
      this.rem += this.period();
      this.csr |= 0o200;
      if (this.csr & 0o100) this.irq(VEC_PCLK, 6);
    }
  }

  reset(): void {
    this.csr = 0;
    this.preset = 0;
    this.rem = 0;
  }
}
