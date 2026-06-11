import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { assemble } from '../src/asm/assembler';
import { Machine } from '../src/core/machine';
import { FB_BASE, JOY_FIRE } from '../src/core/constants';

const source = readFileSync(join(__dirname, '../programs/arkanoid.s'), 'utf8');

function boot() {
  const r = assemble(source);
  expect(r.errors).toEqual([]);
  const m = new Machine();
  m.loadImage(r);
  m.cpu.regs[7] = r.entry;
  m.cpu.regs[6] = 0o060000;
  const sym = (name: string): number => {
    const v = r.symbols.get(name);
    if (v === undefined) throw new Error(`no symbol ${name}`);
    return v;
  };
  return { m, r, sym };
}

describe('arkanoid', () => {
  it('assembles with entry at START', () => {
    const { r } = boot();
    expect(r.entry).toBe(r.symbols.get('START'));
  });

  it('boots: bricks painted, score zeroed, ball stuck on the paddle', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame();
    // top-left brick pixel row (y=64, byte 2)
    expect(m.memory.bytes[FB_BASE + 64 * 64 + 2]).toBe(0xff);
    // top wall at y=16
    expect(m.memory.bytes[FB_BASE + 16 * 64 + 10]).toBe(0xff);
    expect(m.bus.readWord(sym('STUCK'))).toBe(1);
    expect(m.bus.readWord(sym('BRKCNT'))).toBe(90);
    expect(m.bus.readWord(sym('LIVES'))).toBe(3);
  });

  it('fire serves the ball', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame();
    m.joystick.state = JOY_FIRE;
    m.runFrame();
    m.joystick.state = 0;
    expect(m.bus.readWord(sym('STUCK'))).toBe(0);
    const y0 = m.bus.readWord(sym('BALLY'));
    for (let i = 0; i < 30; i++) m.runFrame();
    expect(m.bus.readWord(sym('BALLY'))).toBeLessThan(y0); // flying up
  });

  it('breaks bricks and keeps all lives with a perfect paddle', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame();
    m.joystick.state = JOY_FIRE;
    m.runFrame();
    m.joystick.state = 0;

    const PADB = sym('PADB');
    const BALLX = sym('BALLX');
    for (let i = 0; i < 3600; i++) {
      // autopilot: keep the paddle under the ball
      const target = Math.min(57, Math.max(1, (m.bus.readWord(BALLX) >> 3) - 2));
      m.bus.writeWord(PADB, target);
      m.runFrame();
    }

    expect(m.cpu.halted).toBe(false);
    expect(m.bus.readWord(sym('LIVES'))).toBe(3);
    const broken = 90 - m.bus.readWord(sym('BRKCNT'));
    expect(broken).toBeGreaterThan(0);
    // score is 10 per brick, shown as four decimal digits
    const sc = sym('SCORE');
    const digits = [0, 1, 2, 3].map((i) => m.bus.readByte(sc + i));
    const score = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3];
    expect(score).toBe(broken * 10);
  });

  it('loses a life when the paddle stays in the corner', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame();
    m.joystick.state = JOY_FIRE;
    m.runFrame();
    m.joystick.state = 0;
    const PADB = sym('PADB');
    for (let i = 0; i < 900; i++) {
      m.bus.writeWord(PADB, 1); // hide in the left corner
      m.runFrame();
      if (m.bus.readWord(sym('LIVES')) < 3) break;
    }
    expect(m.bus.readWord(sym('LIVES'))).toBeLessThan(3);
    expect(m.bus.readWord(sym('STUCK'))).toBe(1); // ball back on the paddle
  });
});
