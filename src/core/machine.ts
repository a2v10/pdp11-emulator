import { Bus } from './bus';
import { CPU } from './cpu';
import { Memory } from './memory';
import { KW11 } from './devices/kw11';
import { KW11P } from './devices/kw11p';
import { Joystick } from './devices/joystick';
import { Speaker } from './devices/speaker';
import { CYCLES_PER_FRAME } from './constants';

export interface Snapshot {
  mem: Uint8Array;
  regs: number[];
  psw: number;
  halted: boolean;
  waiting: boolean;
  cycles: number;
  irqs: { vector: number; priority: number }[];
  kw11: number;
  kw11p: { csr: number; preset: number; rem: number };
  joystick: number;
  speaker: number;
}

/** A fully wired machine: memory + bus + CPU + standard devices. */
export class Machine {
  readonly memory = new Memory();
  readonly bus = new Bus(this.memory);
  readonly cpu = new CPU(this.bus);
  readonly kw11: KW11;
  readonly kw11p: KW11P;
  readonly joystick = new Joystick();
  readonly speaker: Speaker;

  constructor() {
    this.kw11 = new KW11((vector, priority) => this.cpu.requestInterrupt(vector, priority));
    this.kw11p = new KW11P((vector, priority) => this.cpu.requestInterrupt(vector, priority));
    this.speaker = new Speaker(() => this.cpu.cycles);
    this.bus.register(this.kw11);
    this.bus.register(this.kw11p);
    this.bus.register(this.joystick);
    this.bus.register(this.speaker);
  }

  reset(): void {
    this.cpu.reset();
    this.bus.resetDevices();
  }

  /** Load a program image directly into RAM (bypasses the bus). */
  loadWords(addr: number, words: readonly number[]): void {
    for (let i = 0; i < words.length; i++) {
      this.memory.words[(addr >> 1) + i] = words[i];
    }
  }

  /** Load an assembled image (structurally matches AsmResult). */
  loadImage(img: { image: Uint8Array; regions: { start: number; end: number }[] }): void {
    for (const r of img.regions) {
      this.memory.bytes.set(img.image.subarray(r.start, r.end), r.start);
    }
  }

  /** Run until the cycle budget is spent or the CPU halts. Returns cycles used. */
  run(maxCycles: number): number {
    const cpu = this.cpu;
    const pclk = this.kw11p;
    let used = 0;
    while (used < maxCycles && !cpu.halted) {
      const spent = cpu.step();
      used += spent;
      pclk.advance(spent);
    }
    return used;
  }

  /** One display frame: clock tick + a frame's worth of CPU time. */
  runFrame(): number {
    this.kw11.tick();
    return this.run(CYCLES_PER_FRAME);
  }

  // ---- snapshot slot: the whole machine is trivially serializable ----

  snapshot(): Snapshot {
    return {
      mem: new Uint8Array(this.memory.bytes),
      regs: Array.from(this.cpu.regs),
      psw: this.cpu.psw,
      halted: this.cpu.halted,
      waiting: this.cpu.waiting,
      cycles: this.cpu.cycles,
      irqs: this.cpu.snapshotIrqs(),
      kw11: this.kw11.lks,
      kw11p: { csr: this.kw11p.csr, preset: this.kw11p.preset, rem: this.kw11p.rem },
      joystick: this.joystick.state,
      speaker: this.speaker.level,
    };
  }

  restore(s: Snapshot): void {
    this.memory.bytes.set(s.mem);
    this.cpu.regs.set(s.regs);
    this.cpu.psw = s.psw;
    this.cpu.halted = s.halted;
    this.cpu.waiting = s.waiting;
    this.cpu.cycles = s.cycles;
    this.cpu.restoreIrqs(s.irqs);
    this.kw11.lks = s.kw11;
    this.kw11p.csr = s.kw11p.csr;
    this.kw11p.preset = s.kw11p.preset;
    this.kw11p.rem = s.kw11p.rem;
    this.joystick.state = s.joystick;
    this.speaker.level = s.speaker;
    this.speaker.events.length = 0;
  }
}
