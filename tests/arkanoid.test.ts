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

  it('the serenade is a real tone off the KW11-P, and serving cuts it', () => {
    const { m } = boot();
    for (let i = 0; i < 10; i++) m.runFrame();
    // ~500 Hz means hundreds of cone flips over a dozen frames; one
    // click per frame (the old busy-loop's failure mode) would be 12
    m.speaker.events.length = 0;
    for (let i = 0; i < 12; i++) m.runFrame();
    expect(m.speaker.events.length / 2).toBeGreaterThan(60);
    m.joystick.state = JOY_FIRE;
    m.runFrame();
    m.joystick.state = 0;
    for (let i = 0; i < 20; i++) m.runFrame(); // let the serve blip end
    m.speaker.events.length = 0;
    for (let i = 0; i < 10; i++) m.runFrame();
    expect(m.speaker.events.length).toBe(0); // the game itself is quiet
  });

  it('the tune plays on through a repaint that outlasts the frame', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame(); // the serenade is running
    m.bus.writeWord(sym('STUCK'), 0);
    m.bus.writeWord(sym('BRKCNT'), 0); // field cleared: INITBR repaints 90.
    const notes = new Set<number>(); //  bricks, which takes several frames
    for (let i = 0; i < 30; i++) {
      m.runFrame();
      notes.add(m.bus.readWord(sym('CURNT')));
    }
    expect(m.bus.readWord(sym('BRKCNT'))).toBe(90);
    expect(m.bus.readWord(sym('INVS'))).toBe(0); // the latch let go again
    expect(m.cpu.halted).toBe(false);
    expect(notes.size).toBeGreaterThan(2); // the clock kept the music going
  });

  it('the last life buzzes its way down, and only then does it HALT', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 5; i++) m.runFrame();
    m.bus.writeWord(sym('LIVES'), 1);
    m.bus.writeWord(sym('STUCK'), 0); // drop the ball past the paddle
    m.bus.writeWord(sym('BALLX'), 0o20);
    m.bus.writeWord(sym('BALLY'), 0o756);
    m.bus.writeWord(sym('BDY'), 2);
    for (let i = 0; i < 10 && !m.cpu.halted; i++) m.runFrame();
    expect(m.bus.readWord(sym('OVER'))).toBeGreaterThan(0);
    expect(m.cpu.halted).toBe(false); // the descent is still sounding
    m.speaker.events.length = 0;
    for (let i = 0; i < 8; i++) m.runFrame();
    expect(m.speaker.events.length / 2).toBeGreaterThan(20);
    for (let i = 0; i < 60 && !m.cpu.halted; i++) m.runFrame();
    expect(m.cpu.halted).toBe(true);
    expect(m.speaker.level).toBe(0); // the cone is left at rest
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
