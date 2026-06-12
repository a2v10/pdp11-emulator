import type { Device } from '../bus';
import { SPK_REG } from '../constants';

/**
 * One-bit speaker, Sinclair Spectrum style: bit 0 of the register is
 * the cone position, the program toggles it at audio rate and the
 * timing of the toggles *is* the sound. There is no tone generator —
 * music costs CPU cycles, like it did in 1982.
 *
 * Each level transition is recorded with its cycle timestamp; the host
 * drains `events` once per frame and synthesizes the waveform.
 */
export class Speaker implements Device {
  readonly name = 'speaker';
  readonly start = SPK_REG;
  readonly end = SPK_REG + 2;
  level = 0;
  /** Flat (cycle, level) pairs accumulated since the last drain. */
  events: number[] = [];

  constructor(private readonly now: () => number) {}

  readWord(): number {
    return this.level;
  }

  writeWord(_addr: number, value: number): void {
    const lv = value & 1;
    if (lv === this.level) return;
    this.level = lv;
    this.events.push(this.now(), lv);
  }

  reset(): void {
    this.level = 0;
    this.events.length = 0;
  }
}
