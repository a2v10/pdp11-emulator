import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { assemble } from '../src/asm/assembler';
import { Machine } from '../src/core/machine';
import { FB_BASE, JOY_RIGHT } from '../src/core/constants';

const source = readFileSync(join(__dirname, '../programs/demo.s'), 'utf8');

describe('demo program (the one shipped in the web editor)', () => {
  it('assembles cleanly with entry at START', () => {
    const r = assemble(source);
    expect(r.errors).toEqual([]);
    expect(r.entry).toBe(r.symbols.get('START'));
  });

  it('runs 180 frames: border drawn, ball moves, paddle follows joystick', () => {
    const r = assemble(source);
    const m = new Machine();
    m.loadImage(r);
    m.cpu.regs[7] = r.entry;
    m.cpu.regs[6] = 0o060000;

    const ballY = (): number => m.bus.readWord(r.symbols.get('BALLY')!);
    const padX = (): number => m.bus.readWord(r.symbols.get('PADX')!);

    m.runFrame();
    // border: full top row lit
    for (let i = 0; i < 64; i++) expect(m.memory.bytes[FB_BASE + i]).toBe(0xff);
    // side columns: leftmost and rightmost pixels of a middle row
    expect(m.memory.bytes[FB_BASE + 256 * 64] & 0x01).toBe(0x01);
    expect(m.memory.bytes[FB_BASE + 256 * 64 + 63] & 0x80).toBe(0x80);

    const y0 = ballY();
    const p0 = padX();
    m.joystick.state = JOY_RIGHT;
    for (let i = 0; i < 180; i++) m.runFrame();

    expect(m.cpu.halted).toBe(false); // the demo idles in WAIT, never halts
    expect(ballY()).not.toBe(y0); // ball moved
    expect(padX()).toBeGreaterThan(p0); // paddle obeyed the joystick
    expect(padX()).toBeLessThanOrEqual(0o70); // and stayed in bounds
  });
});
