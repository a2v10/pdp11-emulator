import { describe, expect, it } from 'vitest';
import { flags, mk, steps } from './helpers';

describe('ALU flags', () => {
  it('ADD carry: 177777 + 1 = 0, Z=1 C=1 V=0', () => {
    const m = mk([0o012700, 0o177777, 0o062700, 1]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0);
    expect(flags(m)).toEqual({ n: 0, z: 1, v: 0, c: 1 });
  });

  it('ADD overflow: 077777 + 1 = 100000, N=1 V=1 C=0', () => {
    const m = mk([0o012700, 0o077777, 0o062700, 1]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o100000);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 1, c: 0 });
  });

  it('SUB borrow: 2 - 3 = 177777, N=1 C=1 V=0', () => {
    const m = mk([0o012700, 2, 0o162700, 3]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o177777);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 1 });
  });

  it('CMP signed vs unsigned: -1 compared with 1', () => {
    // CMP R0(-1), #1: signed -1 < 1 (N^V=1), unsigned 0xffff > 1 (C=0)
    const m = mk([0o012700, 0o177777, 0o020027, 1]);
    steps(m, 2);
    const f = flags(m);
    expect(f.n ^ f.v).toBe(1);
    expect(f.c).toBe(0);
    expect(f.z).toBe(0);
  });

  it('CMP does not modify operands', () => {
    const m = mk([0o022727, 1, 2]); // CMP #1, #2
    steps(m, 1);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 1 });
  });

  it('INC at 077777 sets V', () => {
    const m = mk([0o012700, 0o077777, 0o005200]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o100000);
    expect(flags(m).v).toBe(1);
    expect(flags(m).n).toBe(1);
  });

  it('INC preserves C', () => {
    const m = mk([0o000261, 0o012700, 5, 0o005200]); // SEC; MOV #5,R0; INC R0
    steps(m, 3);
    expect(flags(m).c).toBe(1);
  });

  it('DEC at 100000 sets V', () => {
    const m = mk([0o012700, 0o100000, 0o005300]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o077777);
    expect(flags(m).v).toBe(1);
  });

  it('NEG: of 1 -> 177777 with C=1; of 0 -> C=0 Z=1; of 100000 -> V=1', () => {
    let m = mk([0o012700, 1, 0o005400]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o177777);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 1 });

    m = mk([0o005000, 0o005400]); // CLR R0; NEG R0
    steps(m, 2);
    expect(flags(m)).toEqual({ n: 0, z: 1, v: 0, c: 0 });

    m = mk([0o012700, 0o100000, 0o005400]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o100000);
    expect(flags(m).v).toBe(1);
  });

  it('COM sets C, clears V', () => {
    const m = mk([0o005000, 0o005100]); // CLR R0; COM R0
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o177777);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 1 });
  });

  it('ADC propagates carry: 177777 + C -> 0 with C=1', () => {
    const m = mk([0o012700, 0o177777, 0o000261, 0o005500]); // MOV; SEC; ADC R0
    steps(m, 3);
    expect(m.cpu.regs[0]).toBe(0);
    expect(flags(m)).toEqual({ n: 0, z: 1, v: 0, c: 1 });
  });

  it('SBC borrows: 0 - C -> 177777 with C=1', () => {
    const m = mk([0o005000, 0o000261, 0o005600]); // CLR R0; SEC; SBC R0
    steps(m, 3);
    expect(m.cpu.regs[0]).toBe(0o177777);
    expect(flags(m).c).toBe(1);
  });

  it('BIC clears bits', () => {
    const m = mk([0o012700, 0o177777, 0o042700, 0o000377]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o177400);
    expect(flags(m).n).toBe(1);
  });

  it('BIS sets bits, BIT tests without writing', () => {
    const m = mk([0o012700, 0o000170, 0o052700, 0o000007, 0o032700, 0o000100]);
    steps(m, 3); // MOV #170,R0; BIS #7,R0; BIT #100,R0
    expect(m.cpu.regs[0]).toBe(0o177);
    expect(flags(m).z).toBe(0);
  });

  it('XOR R1, R0', () => {
    const m = mk([0o074100]); // XOR R1, R0
    m.cpu.regs[0] = 0o125252;
    m.cpu.regs[1] = 0o177777;
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0o052525);
  });

  it('CMPB on bytes: 200 vs 100', () => {
    const m = mk([0o122727, 0o200, 0o100]); // CMPB #200, #100
    steps(m, 1);
    // 0x80 - 0x40 = 0x40: N=0, V=1 (signed overflow: -128 - 64), C=0
    expect(flags(m).c).toBe(0);
    expect(flags(m).z).toBe(0);
  });

  it('TSTB sets N from bit 7', () => {
    const m = mk([0o105700]); // TSTB R0
    m.cpu.regs[0] = 0o200;
    steps(m, 1);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 0 });
  });
});

describe('shifts and rotates', () => {
  it('ROR rotates through carry', () => {
    const m = mk([0o000261, 0o012700, 1, 0o006000]); // SEC; MOV #1,R0; ROR R0
    steps(m, 3);
    expect(m.cpu.regs[0]).toBe(0x8000);
    expect(flags(m)).toEqual({ n: 1, z: 0, v: 0, c: 1 }); // V = N^C = 0
  });

  it('ROL shifts carry into bit 0', () => {
    const m = mk([0o000261, 0o012700, 0x8000, 0o006100]); // SEC; MOV; ROL R0
    steps(m, 3);
    expect(m.cpu.regs[0]).toBe(1);
    expect(flags(m).c).toBe(1);
  });

  it('ASR keeps the sign bit', () => {
    const m = mk([0o012700, 0o100002, 0o006200]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0o140001);
    expect(flags(m).c).toBe(0);
  });

  it('ASL: 100000 << 1 = 0, C=1 Z=1 V=1', () => {
    const m = mk([0o012700, 0o100000, 0o006300]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0);
    expect(flags(m)).toEqual({ n: 0, z: 1, v: 1, c: 1 });
  });

  it('SWAB swaps bytes, flags from new low byte', () => {
    const m = mk([0o012700, 0x1234, 0o000300]);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(0x3412);
    expect(flags(m)).toEqual({ n: 0, z: 0, v: 0, c: 0 });
  });

  it('SXT fills from N', () => {
    const m = mk([0o012701, 0o100000, 0o005701, 0o006700]); // MOV #100000,R1; TST R1; SXT R0
    steps(m, 3);
    expect(m.cpu.regs[0]).toBe(0o177777);
  });
});
