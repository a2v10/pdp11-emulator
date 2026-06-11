import { describe, expect, it } from 'vitest';
import { ORG, mk, runToHalt, steps } from './helpers';

describe('branches', () => {
  it('BR jumps unconditionally (forward)', () => {
    const m = mk([0o000401, 0, 0o012700, 7, 0]); // BR +1; HALT; MOV #7,R0; HALT
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(7);
  });

  it('BEQ taken when Z is set, skips when not', () => {
    // TST R0 (=0); BEQ +2; MOV #7,R0; MOV #9,R1; HALT
    const m = mk([0o005700, 0o001402, 0o012700, 7, 0o012701, 9, 0]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(0); // skipped
    expect(m.cpu.regs[1]).toBe(9);
  });

  it('BNE not taken when Z is set', () => {
    const m = mk([0o005700, 0o001002, 0o012700, 7, 0]); // TST R0; BNE +2; MOV #7,R0; HALT
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(7);
  });

  it('backward branch: offset is negative and in words', () => {
    // loop: INC R0; CMP R0,#3; BNE loop; HALT
    const m = mk([0o005200, 0o020027, 3, 0o001374, 0]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(3);
  });

  it('BLT vs BLO distinguish signed from unsigned', () => {
    // R0 = -1; CMP R0, #1
    // BLT taken (signed -1 < 1), then from there BLO (BCS) not taken (unsigned ffff > 1)
    const m = mk([
      0o012700, 0o177777, // MOV #-1, R0
      0o020027, 1, //        CMP R0, #1
      0o002403, //           BLT +3  -> to "signed" (over MOV+HALT)
      0o012701, 1, //        MOV #1, R1   (signed branch missed)
      0, //                  HALT
      // signed:
      0o012702, 1, //        MOV #1, R2
      0o020027, 1, //        CMP R0, #1
      0o103403, //           BCS +3  -> to "unsigned" (must NOT be taken)
      0o012703, 1, //        MOV #1, R3
      0, //                  HALT
      0o012704, 1, //        MOV #1, R4
      0, //                  HALT
    ]);
    runToHalt(m);
    expect(m.cpu.regs[1]).toBe(0);
    expect(m.cpu.regs[2]).toBe(1);
    expect(m.cpu.regs[3]).toBe(1);
    expect(m.cpu.regs[4]).toBe(0);
  });

  it('BHI: unsigned greater', () => {
    // CMP #2, #1 -> 2 > 1 unsigned: C=0 Z=0 -> BHI taken
    const m = mk([0o022727, 2, 1, 0o101002, 0o012700, 7, 0o012701, 9, 0]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(0);
    expect(m.cpu.regs[1]).toBe(9);
  });

  it('SOB loops exactly N times', () => {
    // MOV #5,R1; loop: INC R0; SOB R1, loop; HALT
    const m = mk([0o012701, 5, 0o005200, 0o077102, 0]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(5);
    expect(m.cpu.regs[1]).toBe(0);
  });

  it('branch offset arithmetic lands where expected', () => {
    const m = mk([0o000402]); // BR +2
    steps(m, 1);
    expect(m.cpu.regs[7]).toBe(ORG + 2 + 4);
  });
});
