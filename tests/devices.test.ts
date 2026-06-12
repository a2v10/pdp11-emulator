import { describe, expect, it } from 'vitest';
import { ORG, mk, runToHalt, steps } from './helpers';
import { JOY_FIRE, JOY_LEFT, JOY_REG, KW11_LKS, SPK_REG } from '../src/core/constants';

describe('KW11 line clock', () => {
  it('tick sets the monitor bit', () => {
    const m = mk([]);
    m.kw11.tick();
    expect(m.bus.readWord(KW11_LKS) & 0o200).toBe(0o200);
  });

  it('no interrupt when enable bit is clear', () => {
    const m = mk([0o005200, 0o005200, 0]); // INC R0; INC R0; HALT
    m.loadWords(0o100, [0o2000, 0o340]);
    m.kw11.tick();
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(2); // ran straight through
  });

  it('interrupts through vector 100 when enabled, wakes WAIT', () => {
    const handler = 0o2000;
    // MOV #100,@#LKS (enable); WAIT; MOV #7,R1; HALT
    const m = mk([0o012737, 0o100, KW11_LKS, 0o000001, 0o012701, 7, 0]);
    m.loadWords(0o100, [handler, 0o340]);
    m.loadWords(handler, [0o005200, 0o000002]); // INC R0; RTI
    steps(m, 3); // MOV; WAIT; idle step
    expect(m.cpu.waiting).toBe(true);
    m.kw11.tick();
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(1); // handler ran once
    expect(m.cpu.regs[1]).toBe(7); // execution continued after WAIT
  });

  it('priority masks interrupts: PSW priority 7 blocks the clock', () => {
    const m = mk([0o005200, 0o005200, 0]);
    m.loadWords(0o100, [0o2000, 0o340]);
    m.kw11.lks = 0o100; // interrupts enabled
    m.cpu.psw = 0o340; // priority 7
    m.kw11.tick();
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(2); // handler never ran
  });
});

describe('joystick', () => {
  it('program reads the held-buttons mask', () => {
    const m = mk([0o013700, JOY_REG, 0]); // MOV @#JOY, R0; HALT
    m.joystick.state = JOY_LEFT | JOY_FIRE;
    runToHalt(m);
    expect(m.cpu.regs[0]).toBe(5);
  });

  it('writes are ignored', () => {
    const m = mk([]);
    m.bus.writeWord(JOY_REG, 0o777);
    expect(m.bus.readWord(JOY_REG)).toBe(0);
  });
});

describe('speaker', () => {
  it('program toggles record cycle-stamped transitions', () => {
    // MOV #1,@#SPK; CLR @#SPK; HALT
    const m = mk([0o012737, 1, SPK_REG, 0o005037, SPK_REG, 0]);
    runToHalt(m);
    expect(m.speaker.events.length).toBe(4); // two (cycle, level) pairs
    const [t0, l0, t1, l1] = m.speaker.events;
    expect(l0).toBe(1);
    expect(l1).toBe(0);
    expect(t1).toBeGreaterThan(t0);
  });

  it('only bit 0 matters; same-level writes are not recorded', () => {
    const m = mk([]);
    m.bus.writeWord(SPK_REG, 1);
    m.bus.writeWord(SPK_REG, 0o177777); // bit 0 unchanged
    expect(m.speaker.events.length).toBe(2);
    expect(m.bus.readWord(SPK_REG)).toBe(1);
  });

  it('reset returns the cone to rest and clears the log', () => {
    const m = mk([]);
    m.bus.writeWord(SPK_REG, 1);
    m.reset();
    expect(m.speaker.level).toBe(0);
    expect(m.speaker.events.length).toBe(0);
  });
});

describe('trace slot', () => {
  it('tracer receives one event per instruction', () => {
    const m = mk([0o012700, 5, 0o005200, 0]); // MOV #5,R0; INC R0; HALT
    const names: string[] = [];
    m.cpu.tracer = (e) => names.push(`${e.name}@${e.pc.toString(8)}`);
    runToHalt(m);
    expect(names).toEqual(['MOV@1000', 'INC@1004', 'HALT@1006']);
  });
});

describe('snapshot slot', () => {
  it('restore brings the machine back exactly', () => {
    const m = mk([0o005200, 0o005200, 0o005200, 0o005200, 0]); // INC R0 x4; HALT
    steps(m, 2);
    const snap = m.snapshot();
    const pcAt2 = m.cpu.regs[7];
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(4);
    m.restore(snap);
    expect(m.cpu.regs[0]).toBe(2);
    expect(m.cpu.regs[7]).toBe(pcAt2);
    steps(m, 2);
    expect(m.cpu.regs[0]).toBe(4); // deterministic replay
  });
});

describe('integration: paint the first framebuffer row', () => {
  it('fills 64 bytes at FB_BASE via MOVB (R0)+ and SOB', () => {
    // MOV #FB,R0; MOV #64.,R1; loop: MOVB #377,(R0)+; SOB R1,loop; HALT
    const m = mk([0o012700, 0o060000, 0o012701, 64, 0o112720, 0o377, 0o077103, 0]);
    runToHalt(m);
    for (let i = 0; i < 64; i++) expect(m.memory.bytes[0o060000 + i]).toBe(0xff);
    expect(m.memory.bytes[0o060000 + 64]).toBe(0);
    expect(m.cpu.cycles).toBeGreaterThan(64 * 4);
  });
});

// keep ORG import alive for clarity of addresses in comments
void ORG;
