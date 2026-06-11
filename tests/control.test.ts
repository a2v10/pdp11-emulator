import { describe, expect, it } from 'vitest';
import { ORG, mk, runToHalt, steps } from './helpers';

describe('subroutines', () => {
  it('JSR PC / RTS PC: call and return, stack balanced', () => {
    const sub = ORG + 0o12; // word index 5
    // JSR PC,@#sub; MOV #5,R1; HALT; sub: INC R0; RTS PC
    const m = mk([0o004737, sub, 0o012701, 5, 0, 0o005200, 0o000207]);
    const sp0 = m.cpu.regs[6];
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(1);
    expect(m.cpu.regs[1]).toBe(5);
    expect(m.cpu.regs[6]).toBe(sp0);
  });

  it('JSR R5 linkage: R5 holds the return address inside, restored after', () => {
    const sub = ORG + 0o12;
    // JSR R5,@#sub; MOV #5,R1; HALT; sub: MOV R5,R0; RTS R5
    const m = mk([0o004537, sub, 0o012701, 5, 0, 0o010500, 0o000205]);
    m.cpu.regs[5] = 0o7777;
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(ORG + 4); // return address was in R5
    expect(m.cpu.regs[5]).toBe(0o7777); // old R5 restored
    expect(m.cpu.regs[1]).toBe(5);
  });

  it('nested calls return in the right order', () => {
    const sub1 = ORG + 0o12;
    const sub2 = ORG + 0o22;
    // main: JSR PC,sub1; MOV #1,R1; HALT
    // sub1: JSR PC,sub2; INC R0; RTS PC
    // sub2: INC R0; RTS PC
    const m = mk([
      0o004737, sub1, 0o012701, 1, 0,
      0o004737, sub2, 0o005200, 0o000207,
      0o005200, 0o000207,
    ]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(2);
    expect(m.cpu.regs[1]).toBe(1);
  });
});

describe('traps and interrupts plumbing', () => {
  it('TRAP pushes PSW+PC, enters handler with vector PSW, RTI returns', () => {
    const handler = 0o2000;
    const m = mk([0o104407, 0o012701, 1, 0]); // TRAP 7; MOV #1,R1; HALT
    m.loadWords(0o34, [handler, 0o340]);
    m.loadWords(handler, [0o005200, 0o000002]); // INC R0; RTI
    steps(m, 1); // TRAP serviced
    expect(m.cpu.regs[7]).toBe(handler);
    expect(m.cpu.psw).toBe(0o340);
    // old PC (after TRAP word) and old PSW are on the stack
    expect(m.bus.readWord(m.cpu.regs[6])).toBe(ORG + 2);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(1);
    expect(m.cpu.regs[1]).toBe(1);
  });

  it('EMT dispatches through vector 30', () => {
    const handler = 0o2000;
    const m = mk([0o104000, 0]); // EMT 0; HALT
    m.loadWords(0o30, [handler, 0o340]);
    m.loadWords(handler, [0o005200, 0o000002]);
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(1);
  });

  it('odd word address traps through vector 4', () => {
    const handler = 0o2000;
    const m = mk([0o013700, 0o1001, 0o012701, 7, 0]); // MOV @#1001,R0 (odd!)
    m.loadWords(0o4, [handler, 0o340]);
    m.loadWords(handler, [0]); // HALT
    runToHalt(m);
    expect(m.cpu.regs[7]).toBe(handler + 2);
    expect(m.cpu.regs[1]).toBe(0); // never reached
  });

  it('reserved opcode traps through vector 10', () => {
    const handler = 0o2000;
    const m = mk([0o000010, 0]); // unassigned opcode
    m.loadWords(0o10, [handler, 0o340]);
    m.loadWords(handler, [0]);
    runToHalt(m);
    expect(m.cpu.regs[7]).toBe(handler + 2);
  });

  it('JMP to a register is illegal and traps', () => {
    const handler = 0o2000;
    const m = mk([0o000100, 0]); // JMP R0
    m.loadWords(0o4, [handler, 0o340]);
    m.loadWords(handler, [0]);
    runToHalt(m);
    expect(m.cpu.regs[7]).toBe(handler + 2);
  });

  it('double fault halts the machine', () => {
    // vector 4 contains an odd handler address -> servicing the trap traps again
    const m = mk([0o013700, 0o1001]); // odd address read
    m.loadWords(0o4, [0o1001, 0o340]); // handler PC itself is odd
    m.cpu.regs[6] = 1; // and the stack is odd too, for good measure
    steps(m, 1);
    expect(m.cpu.halted).toBe(true);
  });

  it('HALT stops stepping', () => {
    const m = mk([0, 0o005200]); // HALT; INC R0
    steps(m, 5);
    expect(m.cpu.regs[0]).toBe(0);
    expect(m.cpu.halted).toBe(true);
  });

  it('condition-code ops set and clear flags', () => {
    const m = mk([0o000277, 0o000242]); // SCC (set all); CLZ+CLV? no: 242 = clear V
    steps(m, 1);
    expect(m.cpu.psw & 0o17).toBe(0o17);
    steps(m, 1);
    expect(m.cpu.psw & 0o17).toBe(0o15); // V cleared
  });
});
