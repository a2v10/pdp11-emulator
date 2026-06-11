import { describe, expect, it } from 'vitest';
import { ORG, mk, steps } from './helpers';

describe('addressing modes', () => {
  it('mode 0: MOV R1, R0', () => {
    const m = mk([0o010100]);
    m.cpu.regs[1] = 0o4321;
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0o4321);
  });

  it('mode 2 with PC: immediate MOV #5, R0', () => {
    const m = mk([0o012700, 5]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(5);
    expect(m.cpu.regs[7]).toBe(ORG + 4);
  });

  it('mode 3 with PC: absolute MOV @#2000, R0', () => {
    const m = mk([0o013700, 0o2000]);
    m.loadWords(0o2000, [0o7777]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0o7777);
  });

  it('mode 1: MOV (R1), R0', () => {
    const m = mk([0o011100]);
    m.cpu.regs[1] = 0o2000;
    m.loadWords(0o2000, [42]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(42);
  });

  it('mode 2: MOV (R1)+, R0 increments by 2', () => {
    const m = mk([0o012100]);
    m.cpu.regs[1] = 0o2000;
    m.loadWords(0o2000, [42]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(42);
    expect(m.cpu.regs[1]).toBe(0o2002);
  });

  it('byte autoincrement steps by 1 for R0..R5: MOVB (R1)+, R0', () => {
    const m = mk([0o112100]);
    m.cpu.regs[1] = 0o2000;
    m.memory.bytes[0o2000] = 0x42;
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0x42);
    expect(m.cpu.regs[1]).toBe(0o2001);
  });

  it('mode 4: MOV -(R1), R0 decrements first', () => {
    const m = mk([0o014100]);
    m.cpu.regs[1] = 0o2002;
    m.loadWords(0o2000, [42]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(42);
    expect(m.cpu.regs[1]).toBe(0o2000);
  });

  it('mode 3: MOV @(R1)+, R0 follows the pointer', () => {
    const m = mk([0o013100]);
    m.cpu.regs[1] = 0o2000;
    m.loadWords(0o2000, [0o3000]);
    m.loadWords(0o3000, [99]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(99);
    expect(m.cpu.regs[1]).toBe(0o2002);
  });

  it('mode 6: MOV 2(R1), R0 indexes', () => {
    const m = mk([0o016100, 2]);
    m.cpu.regs[1] = 0o2000;
    m.loadWords(0o2002, [77]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(77);
  });

  it('mode 7: MOV @2(R1), R0 indexes then follows the pointer', () => {
    const m = mk([0o017100, 2]);
    m.cpu.regs[1] = 0o2000;
    m.loadWords(0o2002, [0o3000]);
    m.loadWords(0o3000, [88]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(88);
  });

  it('mode 6 with PC: PC-relative addressing', () => {
    // ORG:   MOV data(PC), R0   ; x = +2 -> data at ORG+6
    // ORG+4: HALT
    // ORG+6: data = 4242
    const m = mk([0o016700, 2, 0, 0o4242]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0o4242);
  });

  it('MOVB #200, R0 sign-extends into the register', () => {
    const m = mk([0o112700, 0o200]);
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0o177600);
  });

  it('byte write to a register keeps the high byte (non-MOVB)', () => {
    // INCB R0 with R0 = 0xAB00 -> 0xAB01
    const m = mk([0o105200]);
    m.cpu.regs[0] = 0xab00;
    steps(m, 1);
    expect(m.cpu.regs[0]).toBe(0xab01);
  });

  it('SP autoincrement steps by 2 even for byte ops: MOVB (R6)+, R0', () => {
    const m = mk([0o112600]);
    m.cpu.regs[6] = 0o2000;
    m.memory.bytes[0o2000] = 7;
    steps(m, 1);
    expect(m.cpu.regs[6]).toBe(0o2002);
  });
});
