import { Bus } from './bus';
import { CpuTrap } from './trap';
import { decode } from './instructions';

// PSW bits
export const FLAG_C = 0o1;
export const FLAG_V = 0o2;
export const FLAG_Z = 0o4;
export const FLAG_N = 0o10;
export const FLAG_T = 0o20;
// bits 5..7 = processor priority

/**
 * Operand "place": either a memory address (0..0xffff) or a register,
 * encoded as PLACE_REG | n. A plain integer so operand resolution
 * allocates nothing on the hot path.
 */
export const PLACE_REG = 0x10000;
export const isRegPlace = (place: number): boolean => place >= PLACE_REG;

/** Per-instruction trace event — the hook the visual debugger feeds on. */
export interface TraceEvent {
  pc: number;
  word: number;
  name: string;
  psw: number;
}
export type Tracer = (e: TraceEvent) => void;

interface IrqRequest {
  vector: number;
  priority: number;
}

export class CPU {
  /** R0..R5, R6 = SP, R7 = PC */
  readonly regs = new Uint16Array(8);
  psw = 0;
  halted = false;
  waiting = false;
  /** Running cycle counter (approximate machine cycles). */
  cycles = 0;
  /** Set to receive one event per executed instruction; null = zero overhead. */
  tracer: Tracer | null = null;
  private pending: IrqRequest[] = [];

  constructor(readonly bus: Bus) {}

  reset(): void {
    this.regs.fill(0);
    this.psw = 0;
    this.halted = false;
    this.waiting = false;
    this.cycles = 0;
    this.pending.length = 0;
  }

  /** Current processor priority (PSW bits 5..7). */
  get priority(): number {
    return (this.psw >> 5) & 7;
  }

  requestInterrupt(vector: number, priority: number): void {
    if (this.pending.some((p) => p.vector === vector)) return;
    this.pending.push({ vector, priority });
    this.pending.sort((a, b) => b.priority - a.priority);
  }

  /** Execute one instruction (or service one interrupt). Returns cycles spent. */
  step(): number {
    if (this.halted) return 0;

    if (this.pending.length > 0 && this.pending[0].priority > this.priority) {
      const req = this.pending.shift()!;
      this.waiting = false;
      this.serviceTrap(req.vector);
      this.cycles += 6;
      return 6;
    }

    if (this.waiting) {
      this.cycles += 1;
      return 1;
    }

    const pc0 = this.regs[7];
    let spent: number;
    try {
      const word = this.fetchWord();
      const def = decode(word);
      spent = def.exec(this, word);
      if (this.tracer !== null) this.tracer({ pc: pc0, word, name: def.name, psw: this.psw });
    } catch (e) {
      if (!(e instanceof CpuTrap)) throw e;
      this.serviceTrap(e.vector);
      spent = 8;
    }
    this.cycles += spent;
    return spent;
  }

  /** Push PSW+PC and enter the handler whose address sits at `vector`. */
  private serviceTrap(vector: number): void {
    try {
      const newPc = this.bus.readWord(vector);
      const newPsw = this.bus.readWord(vector + 2);
      this.push(this.psw);
      this.push(this.regs[7]);
      this.regs[7] = newPc;
      this.psw = newPsw;
    } catch {
      this.halted = true; // double fault: broken vector or stack, stop the machine
    }
  }

  // ---- low-level API used by the instruction table ----

  fetchWord(): number {
    const pc = this.regs[7];
    const w = this.bus.readWord(pc);
    this.regs[7] = (pc + 2) & 0xffff;
    return w;
  }

  /**
   * Resolve a 6-bit operand specifier (mode << 3 | reg) to a place,
   * applying autoincrement/decrement side effects. Byte-wide operations
   * step R0..R5 by 1; SP and PC always step by 2.
   */
  resolve(spec: number, byte: boolean): number {
    const mode = (spec >> 3) & 7;
    const r = spec & 7;
    const regs = this.regs;
    const step = byte && r < 6 ? 1 : 2;
    switch (mode) {
      case 0: // Rn
        return PLACE_REG | r;
      case 1: // (Rn)
        return regs[r];
      case 2: {
        // (Rn)+  — with R7 this is an immediate
        const a = regs[r];
        regs[r] = (a + step) & 0xffff;
        return a;
      }
      case 3: {
        // @(Rn)+
        const a = regs[r];
        regs[r] = (a + 2) & 0xffff;
        return this.bus.readWord(a);
      }
      case 4: {
        // -(Rn)
        const a = (regs[r] - step) & 0xffff;
        regs[r] = a;
        return a;
      }
      case 5: {
        // @-(Rn)
        const a = (regs[r] - 2) & 0xffff;
        regs[r] = a;
        return this.bus.readWord(a);
      }
      case 6: {
        // X(Rn)  — with R7 this is PC-relative
        const x = this.fetchWord();
        return (regs[r] + x) & 0xffff;
      }
      default: {
        // @X(Rn)
        const x = this.fetchWord();
        return this.bus.readWord((regs[r] + x) & 0xffff);
      }
    }
  }

  readPlace(place: number, byte: boolean): number {
    if (place >= PLACE_REG) {
      const v = this.regs[place & 7];
      return byte ? v & 0xff : v;
    }
    return byte ? this.bus.readByte(place) : this.bus.readWord(place);
  }

  writePlace(place: number, value: number, byte: boolean): void {
    if (place >= PLACE_REG) {
      const r = place & 7;
      if (byte) this.regs[r] = (this.regs[r] & 0xff00) | (value & 0xff);
      else this.regs[r] = value;
    } else if (byte) {
      this.bus.writeByte(place, value);
    } else {
      this.bus.writeWord(place, value);
    }
  }

  push(value: number): void {
    const sp = (this.regs[6] - 2) & 0xffff;
    this.regs[6] = sp;
    this.bus.writeWord(sp, value);
  }

  pop(): number {
    const v = this.bus.readWord(this.regs[6]);
    this.regs[6] = (this.regs[6] + 2) & 0xffff;
    return v;
  }

  // ---- condition codes (truthy arguments are fine) ----

  /** Set N, Z, V; preserve C. */
  setNZV(n: number | boolean, z: number | boolean, v: number | boolean): void {
    this.psw =
      (this.psw & ~(FLAG_N | FLAG_Z | FLAG_V)) | (n ? FLAG_N : 0) | (z ? FLAG_Z : 0) | (v ? FLAG_V : 0);
  }

  /** Set all four condition codes. */
  setNZVC(n: number | boolean, z: number | boolean, v: number | boolean, c: number | boolean): void {
    this.psw =
      (this.psw & ~(FLAG_N | FLAG_Z | FLAG_V | FLAG_C)) |
      (n ? FLAG_N : 0) |
      (z ? FLAG_Z : 0) |
      (v ? FLAG_V : 0) |
      (c ? FLAG_C : 0);
  }

  // ---- state snapshot slot ----

  snapshotIrqs(): IrqRequest[] {
    return this.pending.map((p) => ({ ...p }));
  }

  restoreIrqs(list: IrqRequest[]): void {
    this.pending = list.map((p) => ({ ...p }));
  }
}
