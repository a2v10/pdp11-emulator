import type { CPU } from './cpu';
import { isRegPlace } from './cpu';
import { CpuTrap } from './trap';
import { VEC_BPT, VEC_EMT, VEC_IOT, VEC_ODD, VEC_RESERVED, VEC_TRAP } from './constants';

/**
 * The instruction set lives here in two cooperating forms:
 *
 * 1. decode() — a cascade of nested switches over the octal fields of the
 *    instruction word: the software analog of the combinational decode
 *    network in the real processor. This is what the CPU executes through.
 *
 * 2. DEFS — the "programmer's reference card": every instruction with its
 *    pattern/mask, operand format and functional units. The assembler,
 *    disassembler and the UI feed on this data.
 *
 * A test cross-checks the two on all 65536 opcode words, so the card can
 * never lie about the hardware.
 */

/** Operand layout, for the assembler/disassembler. */
export type Format =
  | 'none' // HALT, RTI, ...
  | 'reg' // RTS R
  | 'single' // op DD
  | 'double' // op SS, DD
  | 'regsrc' // JSR R, DD / XOR R, DD
  | 'branch' // op offset
  | 'sob' // SOB R, offset
  | 'trapn' // EMT/TRAP n
  | 'cc'; // condition-code ops

/** Functional units involved — slot for the visual CPU schematic. */
export type Unit = 'alu' | 'shifter' | 'branch' | 'stack' | 'control' | 'bus';

export interface InstrDef {
  readonly name: string;
  readonly pattern: number;
  readonly mask: number;
  readonly fmt: Format;
  readonly units: readonly Unit[];
  readonly exec: (cpu: CPU, w: number) => number; // returns cycles (approximate)
}

// Rough cost of operand fetch per addressing mode.
const MODE_COST = [0, 1, 2, 2, 2, 3, 3, 4];
const srcCost = (w: number): number => MODE_COST[(w >> 9) & 7];
const dstCost = (w: number): number => MODE_COST[(w >> 3) & 7];

const def = (
  name: string,
  pattern: number,
  mask: number,
  fmt: Format,
  units: readonly Unit[],
  exec: (cpu: CPU, w: number) => number,
): InstrDef => ({ name, pattern, mask, fmt, units, exec });

// ---- double-operand ----

function execMov(cpu: CPU, w: number): number {
  const v = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, false), false);
  cpu.writePlace(cpu.resolve(w & 0o77, false), v, false);
  cpu.setNZV(v & 0x8000, v === 0, 0);
  return 2 + srcCost(w) + dstCost(w);
}

function execMovb(cpu: CPU, w: number): number {
  const v = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, true), true);
  const dst = cpu.resolve(w & 0o77, true);
  // MOVB to a register sign-extends into the full word (unique to MOVB)
  if (isRegPlace(dst)) cpu.regs[dst & 7] = v & 0x80 ? v | 0xff00 : v;
  else cpu.writePlace(dst, v, true);
  cpu.setNZV(v & 0x80, v === 0, 0);
  return 2 + srcCost(w) + dstCost(w);
}

function makeCmp(byte: boolean) {
  const SIGN = byte ? 0x80 : 0x8000;
  const MASK = byte ? 0xff : 0xffff;
  return (cpu: CPU, w: number): number => {
    const s = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, byte), byte);
    const d = cpu.readPlace(cpu.resolve(w & 0o77, byte), byte);
    const r = (s - d) & MASK;
    cpu.setNZVC(r & SIGN, r === 0, (s ^ d) & (s ^ r) & SIGN, s < d);
    return 2 + srcCost(w) + dstCost(w);
  };
}

function makeLogic(byte: boolean, op: (s: number, d: number) => number, write: boolean) {
  const SIGN = byte ? 0x80 : 0x8000;
  const MASK = byte ? 0xff : 0xffff;
  return (cpu: CPU, w: number): number => {
    const s = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, byte), byte);
    const place = cpu.resolve(w & 0o77, byte);
    const d = cpu.readPlace(place, byte);
    const r = op(s, d) & MASK;
    if (write) cpu.writePlace(place, r, byte);
    cpu.setNZV(r & SIGN, r === 0, 0);
    return 2 + srcCost(w) + dstCost(w);
  };
}

function execAdd(cpu: CPU, w: number): number {
  const s = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, false), false);
  const place = cpu.resolve(w & 0o77, false);
  const d = cpu.readPlace(place, false);
  const sum = s + d;
  const r = sum & 0xffff;
  cpu.writePlace(place, r, false);
  cpu.setNZVC(r & 0x8000, r === 0, ~(s ^ d) & (s ^ r) & 0x8000, sum > 0xffff);
  return 2 + srcCost(w) + dstCost(w);
}

function execSub(cpu: CPU, w: number): number {
  const s = cpu.readPlace(cpu.resolve((w >> 6) & 0o77, false), false);
  const place = cpu.resolve(w & 0o77, false);
  const d = cpu.readPlace(place, false);
  const r = (d - s) & 0xffff;
  cpu.writePlace(place, r, false);
  cpu.setNZVC(r & 0x8000, r === 0, (d ^ s) & (d ^ r) & 0x8000, d < s);
  return 2 + srcCost(w) + dstCost(w);
}

// ---- single-operand ----

/** Read-modify-write helper: `fn` computes the result and sets flags. */
function rmw(cpu: CPU, w: number, byte: boolean, fn: (cpu: CPU, d: number) => number): number {
  const place = cpu.resolve(w & 0o77, byte);
  const d = cpu.readPlace(place, byte);
  cpu.writePlace(place, fn(cpu, d), byte);
  return 2 + dstCost(w);
}

interface ByteParams {
  SIGN: number;
  MASK: number;
  MAXPOS: number;
}
const params = (byte: boolean): ByteParams =>
  byte ? { SIGN: 0x80, MASK: 0xff, MAXPOS: 0x7f } : { SIGN: 0x8000, MASK: 0xffff, MAXPOS: 0x7fff };

function makeClr(byte: boolean) {
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c) => {
      c.setNZVC(0, 1, 0, 0);
      return 0;
    });
}

function makeCom(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const r = ~d & MASK;
      c.setNZVC(r & SIGN, r === 0, 0, 1);
      return r;
    });
}

function makeInc(byte: boolean) {
  const { SIGN, MASK, MAXPOS } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const r = (d + 1) & MASK;
      c.setNZV(r & SIGN, r === 0, d === MAXPOS); // C preserved
      return r;
    });
}

function makeDec(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const r = (d - 1) & MASK;
      c.setNZV(r & SIGN, r === 0, d === SIGN); // C preserved
      return r;
    });
}

function makeNeg(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const r = -d & MASK;
      c.setNZVC(r & SIGN, r === 0, r === SIGN, r !== 0);
      return r;
    });
}

function makeAdc(byte: boolean) {
  const { SIGN, MASK, MAXPOS } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carry = c.psw & 1;
      const r = (d + carry) & MASK;
      c.setNZVC(r & SIGN, r === 0, d === MAXPOS && carry, d === MASK && carry);
      return r;
    });
}

function makeSbc(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carry = c.psw & 1;
      const r = (d - carry) & MASK;
      c.setNZVC(r & SIGN, r === 0, d === SIGN, d === 0 && carry);
      return r;
    });
}

function makeTst(byte: boolean) {
  const { SIGN } = params(byte);
  return (cpu: CPU, w: number): number => {
    const d = cpu.readPlace(cpu.resolve(w & 0o77, byte), byte);
    cpu.setNZVC(d & SIGN, d === 0, 0, 0);
    return 2 + dstCost(w);
  };
}

// Shifts and rotates: V = N xor C after the operation.

function makeRor(byte: boolean) {
  const { SIGN } = params(byte);
  const topShift = byte ? 7 : 15;
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carryIn = c.psw & 1;
      const carryOut = d & 1;
      const r = (carryIn << topShift) | (d >> 1);
      const n = r & SIGN ? 1 : 0;
      c.setNZVC(n, r === 0, n ^ carryOut, carryOut);
      return r;
    });
}

function makeRol(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  const topShift = byte ? 7 : 15;
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carryOut = (d >> topShift) & 1;
      const r = ((d << 1) | (c.psw & 1)) & MASK;
      const n = r & SIGN ? 1 : 0;
      c.setNZVC(n, r === 0, n ^ carryOut, carryOut);
      return r;
    });
}

function makeAsr(byte: boolean) {
  const { SIGN } = params(byte);
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carryOut = d & 1;
      const r = (d & SIGN) | (d >> 1);
      const n = r & SIGN ? 1 : 0;
      c.setNZVC(n, r === 0, n ^ carryOut, carryOut);
      return r;
    });
}

function makeAsl(byte: boolean) {
  const { SIGN, MASK } = params(byte);
  const topShift = byte ? 7 : 15;
  return (cpu: CPU, w: number): number =>
    rmw(cpu, w, byte, (c, d) => {
      const carryOut = (d >> topShift) & 1;
      const r = (d << 1) & MASK;
      const n = r & SIGN ? 1 : 0;
      c.setNZVC(n, r === 0, n ^ carryOut, carryOut);
      return r;
    });
}

function execSwab(cpu: CPU, w: number): number {
  return rmw(cpu, w, false, (c, d) => {
    const r = ((d & 0xff) << 8) | ((d >> 8) & 0xff);
    c.setNZVC(r & 0x80, (r & 0xff) === 0, 0, 0); // flags from the new low byte
    return r;
  });
}

function execSxt(cpu: CPU, w: number): number {
  const place = cpu.resolve(w & 0o77, false);
  const n = (cpu.psw >> 3) & 1;
  const r = n ? 0xffff : 0;
  cpu.writePlace(place, r, false);
  // N and C unaffected, Z = !N, V cleared
  cpu.psw = (cpu.psw & ~0o6) | (n ? 0 : 0o4);
  return 2 + dstCost(w);
}

// ---- control flow ----

function execJmp(cpu: CPU, w: number): number {
  const place = cpu.resolve(w & 0o77, false);
  if (isRegPlace(place)) throw new CpuTrap(VEC_ODD); // register-mode jump is illegal
  cpu.regs[7] = place;
  return 1 + dstCost(w);
}

function execJsr(cpu: CPU, w: number): number {
  const r = (w >> 6) & 7;
  const place = cpu.resolve(w & 0o77, false);
  if (isRegPlace(place)) throw new CpuTrap(VEC_ODD);
  cpu.push(cpu.regs[r]);
  cpu.regs[r] = cpu.regs[7];
  cpu.regs[7] = place;
  return 4 + dstCost(w);
}

function execRts(cpu: CPU, w: number): number {
  const r = w & 7;
  cpu.regs[7] = cpu.regs[r];
  cpu.regs[r] = cpu.pop();
  return 4;
}

function execSob(cpu: CPU, w: number): number {
  const r = (w >> 6) & 7;
  cpu.regs[r] = (cpu.regs[r] - 1) & 0xffff;
  if (cpu.regs[r] !== 0) {
    cpu.regs[7] = (cpu.regs[7] - 2 * (w & 0o77)) & 0xffff;
    return 3;
  }
  return 2;
}

function execXor(cpu: CPU, w: number): number {
  const place = cpu.resolve(w & 0o77, false);
  const r = (cpu.readPlace(place, false) ^ cpu.regs[(w >> 6) & 7]) & 0xffff;
  cpu.writePlace(place, r, false);
  cpu.setNZV(r & 0x8000, r === 0, 0);
  return 2 + dstCost(w);
}

const brDef = (name: string, pattern: number, cond: (psw: number) => boolean): InstrDef =>
  def(name, pattern, 0o177400, 'branch', ['branch'], (cpu, w) => {
    if (cond(cpu.psw)) {
      const off = ((w & 0xff) << 24) >> 24; // sign-extend the byte; offset is in words
      cpu.regs[7] = (cpu.regs[7] + off * 2) & 0xffff;
    }
    return 2;
  });

// psw bit helpers for branch conditions
const N = (p: number): number => (p >> 3) & 1;
const Z = (p: number): number => (p >> 2) & 1;
const V = (p: number): number => (p >> 1) & 1;
const C = (p: number): number => p & 1;

function execRti(cpu: CPU): number {
  cpu.regs[7] = cpu.pop();
  cpu.psw = cpu.pop();
  return 5;
}

function execCcOp(cpu: CPU, w: number): number {
  const bits = w & 0o17;
  if (w & 0o20) cpu.psw |= bits;
  else cpu.psw &= ~bits;
  return 1;
}

const trapDef = (name: string, pattern: number, mask: number, fmt: Format, vector: number): InstrDef =>
  def(name, pattern, mask, fmt, ['control', 'stack'], () => {
    throw new CpuTrap(vector);
  });

// ---- the programmer's card: every instruction as a named definition ----

/** Catch-all for unassigned opcodes (incl. EIS/FPU/MMU we don't implement). */
export const RESERVED = def('(reserved)', 0, 0, 'none', ['control'], () => {
  throw new CpuTrap(VEC_RESERVED);
});

const I_HALT = def('HALT', 0o000000, 0o177777, 'none', ['control'], (cpu) => ((cpu.halted = true), 1));
const I_WAIT = def('WAIT', 0o000001, 0o177777, 'none', ['control'], (cpu) => ((cpu.waiting = true), 1));
const I_RTI = def('RTI', 0o000002, 0o177777, 'none', ['control', 'stack'], execRti);
const I_BPT = trapDef('BPT', 0o000003, 0o177777, 'none', VEC_BPT);
const I_IOT = trapDef('IOT', 0o000004, 0o177777, 'none', VEC_IOT);
const I_RESET = def('RESET', 0o000005, 0o177777, 'none', ['control'], (cpu) => (cpu.bus.resetDevices(), 1));
const I_RTT = def('RTT', 0o000006, 0o177777, 'none', ['control', 'stack'], execRti);
const I_RTS = def('RTS', 0o000200, 0o177770, 'reg', ['control', 'stack'], execRts);
const I_CCOP = def('ccop', 0o000240, 0o177740, 'cc', ['control'], execCcOp);
const I_EMT = trapDef('EMT', 0o104000, 0o177400, 'trapn', VEC_EMT);
const I_TRAP = trapDef('TRAP', 0o104400, 0o177400, 'trapn', VEC_TRAP);

const I_JMP = def('JMP', 0o000100, 0o177700, 'single', ['branch'], execJmp);
const I_JSR = def('JSR', 0o004000, 0o177000, 'regsrc', ['branch', 'stack'], execJsr);
const I_SOB = def('SOB', 0o077000, 0o177000, 'sob', ['alu', 'branch'], execSob);

const I_BR = brDef('BR', 0o000400, () => true);
const I_BNE = brDef('BNE', 0o001000, (p) => !Z(p));
const I_BEQ = brDef('BEQ', 0o001400, (p) => Z(p) === 1);
const I_BGE = brDef('BGE', 0o002000, (p) => (N(p) ^ V(p)) === 0);
const I_BLT = brDef('BLT', 0o002400, (p) => (N(p) ^ V(p)) === 1);
const I_BGT = brDef('BGT', 0o003000, (p) => Z(p) === 0 && (N(p) ^ V(p)) === 0);
const I_BLE = brDef('BLE', 0o003400, (p) => Z(p) === 1 || (N(p) ^ V(p)) === 1);
const I_BPL = brDef('BPL', 0o100000, (p) => !N(p));
const I_BMI = brDef('BMI', 0o100400, (p) => N(p) === 1);
const I_BHI = brDef('BHI', 0o101000, (p) => C(p) === 0 && Z(p) === 0);
const I_BLOS = brDef('BLOS', 0o101400, (p) => C(p) === 1 || Z(p) === 1);
const I_BVC = brDef('BVC', 0o102000, (p) => !V(p));
const I_BVS = brDef('BVS', 0o102400, (p) => V(p) === 1);
const I_BCC = brDef('BCC', 0o103000, (p) => !C(p));
const I_BCS = brDef('BCS', 0o103400, (p) => C(p) === 1);

const I_MOV = def('MOV', 0o010000, 0o170000, 'double', ['bus'], execMov);
const I_MOVB = def('MOVB', 0o110000, 0o170000, 'double', ['bus'], execMovb);
const I_CMP = def('CMP', 0o020000, 0o170000, 'double', ['alu'], makeCmp(false));
const I_CMPB = def('CMPB', 0o120000, 0o170000, 'double', ['alu'], makeCmp(true));
const I_BIT = def('BIT', 0o030000, 0o170000, 'double', ['alu'], makeLogic(false, (s, d) => s & d, false));
const I_BITB = def('BITB', 0o130000, 0o170000, 'double', ['alu'], makeLogic(true, (s, d) => s & d, false));
const I_BIC = def('BIC', 0o040000, 0o170000, 'double', ['alu'], makeLogic(false, (s, d) => d & ~s, true));
const I_BICB = def('BICB', 0o140000, 0o170000, 'double', ['alu'], makeLogic(true, (s, d) => d & ~s, true));
const I_BIS = def('BIS', 0o050000, 0o170000, 'double', ['alu'], makeLogic(false, (s, d) => d | s, true));
const I_BISB = def('BISB', 0o150000, 0o170000, 'double', ['alu'], makeLogic(true, (s, d) => d | s, true));
const I_ADD = def('ADD', 0o060000, 0o170000, 'double', ['alu'], execAdd);
const I_SUB = def('SUB', 0o160000, 0o170000, 'double', ['alu'], execSub);

const I_XOR = def('XOR', 0o074000, 0o177000, 'regsrc', ['alu'], execXor);

const I_SWAB = def('SWAB', 0o000300, 0o177700, 'single', ['shifter'], execSwab);
const I_CLR = def('CLR', 0o005000, 0o177700, 'single', ['alu'], makeClr(false));
const I_CLRB = def('CLRB', 0o105000, 0o177700, 'single', ['alu'], makeClr(true));
const I_COM = def('COM', 0o005100, 0o177700, 'single', ['alu'], makeCom(false));
const I_COMB = def('COMB', 0o105100, 0o177700, 'single', ['alu'], makeCom(true));
const I_INC = def('INC', 0o005200, 0o177700, 'single', ['alu'], makeInc(false));
const I_INCB = def('INCB', 0o105200, 0o177700, 'single', ['alu'], makeInc(true));
const I_DEC = def('DEC', 0o005300, 0o177700, 'single', ['alu'], makeDec(false));
const I_DECB = def('DECB', 0o105300, 0o177700, 'single', ['alu'], makeDec(true));
const I_NEG = def('NEG', 0o005400, 0o177700, 'single', ['alu'], makeNeg(false));
const I_NEGB = def('NEGB', 0o105400, 0o177700, 'single', ['alu'], makeNeg(true));
const I_ADC = def('ADC', 0o005500, 0o177700, 'single', ['alu'], makeAdc(false));
const I_ADCB = def('ADCB', 0o105500, 0o177700, 'single', ['alu'], makeAdc(true));
const I_SBC = def('SBC', 0o005600, 0o177700, 'single', ['alu'], makeSbc(false));
const I_SBCB = def('SBCB', 0o105600, 0o177700, 'single', ['alu'], makeSbc(true));
const I_TST = def('TST', 0o005700, 0o177700, 'single', ['alu'], makeTst(false));
const I_TSTB = def('TSTB', 0o105700, 0o177700, 'single', ['alu'], makeTst(true));
const I_ROR = def('ROR', 0o006000, 0o177700, 'single', ['shifter'], makeRor(false));
const I_RORB = def('RORB', 0o106000, 0o177700, 'single', ['shifter'], makeRor(true));
const I_ROL = def('ROL', 0o006100, 0o177700, 'single', ['shifter'], makeRol(false));
const I_ROLB = def('ROLB', 0o106100, 0o177700, 'single', ['shifter'], makeRol(true));
const I_ASR = def('ASR', 0o006200, 0o177700, 'single', ['shifter'], makeAsr(false));
const I_ASRB = def('ASRB', 0o106200, 0o177700, 'single', ['shifter'], makeAsr(true));
const I_ASL = def('ASL', 0o006300, 0o177700, 'single', ['shifter'], makeAsl(false));
const I_ASLB = def('ASLB', 0o106300, 0o177700, 'single', ['shifter'], makeAsl(true));
const I_SXT = def('SXT', 0o006700, 0o177700, 'single', ['alu'], execSxt);

/** The card itself, for the assembler/disassembler/UI. */
export const DEFS: InstrDef[] = [
  I_HALT, I_WAIT, I_RTI, I_BPT, I_IOT, I_RESET, I_RTT, I_RTS, I_CCOP, I_EMT, I_TRAP,
  I_JMP, I_JSR, I_SOB,
  I_BR, I_BNE, I_BEQ, I_BGE, I_BLT, I_BGT, I_BLE,
  I_BPL, I_BMI, I_BHI, I_BLOS, I_BVC, I_BVS, I_BCC, I_BCS,
  I_MOV, I_MOVB, I_CMP, I_CMPB, I_BIT, I_BITB, I_BIC, I_BICB, I_BIS, I_BISB, I_ADD, I_SUB,
  I_XOR,
  I_SWAB, I_CLR, I_CLRB, I_COM, I_COMB, I_INC, I_INCB, I_DEC, I_DECB, I_NEG, I_NEGB,
  I_ADC, I_ADCB, I_SBC, I_SBCB, I_TST, I_TSTB,
  I_ROR, I_RORB, I_ROL, I_ROLB, I_ASR, I_ASRB, I_ASL, I_ASLB, I_SXT,
];

// ---- the decoder ----

/**
 * Hierarchical decode: nested switches over the octal digits of the
 * instruction word, mirroring the combinational decode network of the
 * real machine (and the opcode map page of the Processor Handbook).
 *
 * Bit 15 is the byte/word selector for most groups; bits 14..12 pick
 * the major group; deeper digits refine it.
 */
export function decode(w: number): InstrDef {
  const byte = w & 0x8000;
  switch ((w >> 12) & 7) {
    case 0:
      return decodeGroup0(w, byte);
    case 1:
      return byte ? I_MOVB : I_MOV;
    case 2:
      return byte ? I_CMPB : I_CMP;
    case 3:
      return byte ? I_BITB : I_BIT;
    case 4:
      return byte ? I_BICB : I_BIC;
    case 5:
      return byte ? I_BISB : I_BIS;
    case 6:
      return byte ? I_SUB : I_ADD; // bit 15 turns ADD into SUB
    default:
      // 07xxxx: EIS group; 17xxxx: floating point — absent on this machine
      if (byte) return RESERVED;
      switch ((w >> 9) & 7) {
        case 4:
          return I_XOR; // 074RDD
        case 7:
          return I_SOB; // 077Rnn
        default:
          return RESERVED; // MUL/DIV/ASH/ASHC/FIS
      }
  }
}

function decodeGroup0(w: number, byte: number): InstrDef {
  switch ((w >> 9) & 7) {
    case 0:
      if (byte) return w & 0o400 ? I_BMI : I_BPL; // 100400 / 100000
      switch ((w >> 6) & 7) {
        case 0: // 0000xx: system ops
          switch (w & 0o77) {
            case 0: return I_HALT;
            case 1: return I_WAIT;
            case 2: return I_RTI;
            case 3: return I_BPT;
            case 4: return I_IOT;
            case 5: return I_RESET;
            case 6: return I_RTT;
            default: return RESERVED;
          }
        case 1:
          return I_JMP; // 0001DD
        case 2: // 0002xx: RTS, SPL, condition codes
          switch ((w >> 3) & 7) {
            case 0: return I_RTS; // 00020R
            case 4: case 5: case 6: case 7:
              return I_CCOP; // 000240..000277
            default:
              return RESERVED; // 000210..000237 (incl. SPL)
          }
        case 3:
          return I_SWAB; // 0003DD
        default:
          return I_BR; // 000400..000777
      }
    case 1:
      return byte ? (w & 0o400 ? I_BLOS : I_BHI) : (w & 0o400 ? I_BEQ : I_BNE);
    case 2:
      return byte ? (w & 0o400 ? I_BVS : I_BVC) : (w & 0o400 ? I_BLT : I_BGE);
    case 3:
      return byte ? (w & 0o400 ? I_BCS : I_BCC) : (w & 0o400 ? I_BLE : I_BGT);
    case 4:
      return byte ? (w & 0o400 ? I_TRAP : I_EMT) : I_JSR;
    case 5: // 005xDD / 105xDD: single-operand group
      switch ((w >> 6) & 7) {
        case 0: return byte ? I_CLRB : I_CLR;
        case 1: return byte ? I_COMB : I_COM;
        case 2: return byte ? I_INCB : I_INC;
        case 3: return byte ? I_DECB : I_DEC;
        case 4: return byte ? I_NEGB : I_NEG;
        case 5: return byte ? I_ADCB : I_ADC;
        case 6: return byte ? I_SBCB : I_SBC;
        default: return byte ? I_TSTB : I_TST;
      }
    case 6: // 006xDD / 106xDD: shifts and the group tail
      switch ((w >> 6) & 7) {
        case 0: return byte ? I_RORB : I_ROR;
        case 1: return byte ? I_ROLB : I_ROL;
        case 2: return byte ? I_ASRB : I_ASR;
        case 3: return byte ? I_ASLB : I_ASL;
        case 7: return byte ? RESERVED : I_SXT; // 1067xx = MFPS, absent
        default: return RESERVED; // MARK, MFPI/MTPI, MTPS
      }
    default:
      return RESERVED; // 007xxx / 107xxx unassigned
  }
}
