import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { assemble } from '../src/asm/assembler';
import { Machine } from '../src/core/machine';
import { JOY_DOWN, JOY_LEFT } from '../src/core/constants';

const source = readFileSync(join(__dirname, '../programs/tetris.s'), 'utf8');

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
  // run START through to the WAIT idle loop
  m.runFrame();
  return { m, sym };
}

const row = (m: Machine, board: number, r: number): number => m.bus.readWord(board + r * 2);
const bcd = (m: Machine, base: number, n: number): number => {
  let v = 0;
  for (let i = n - 1; i >= 0; i--) v = v * 10 + m.bus.readByte(base + i);
  return v;
};

function step(m: Machine, n: number, joy = 0): void {
  for (let i = 0; i < n; i++) {
    m.joystick.state = joy;
    m.kw11.tick();
    m.run(16667);
  }
}

// one hard drop: press down (edge-triggered), then release so the next
// piece can be dropped again. `hold` lets a direction be applied first.
function drop(m: Machine, hold = 0, holdFrames = 0): void {
  if (holdFrames) step(m, holdFrames, hold);
  step(m, 1, hold | JOY_DOWN);
  step(m, 1, 0);
}

describe('tetris', () => {
  it('assembles with entry at START', () => {
    const r = assemble(source);
    expect(r.errors).toEqual([]);
    expect(r.entry).toBe(r.symbols.get('START'));
  });

  it('spawns a piece that falls under gravity', () => {
    const { m, sym } = boot();
    const CURY = sym('CURY');
    const y0 = m.bus.readWord(CURY);
    step(m, 60); // a second of real time, no input
    expect(m.bus.readWord(CURY)).toBeGreaterThan(y0);
    expect(m.cpu.halted).toBe(false);
  });

  it('one down press hard-drops the piece to the floor', () => {
    const { m, sym } = boot();
    const BOARD = sym('BOARD');
    drop(m); // single press: lands and locks
    // something now sits on the bottom row
    expect(row(m, BOARD, 19)).not.toBe(0);
  });

  it('hard-dropped pieces pile up and eventually top out', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 60 && !m.cpu.halted; i++) drop(m);
    expect(m.cpu.halted).toBe(true); // game over, centre column full
    let occupied = 0;
    for (let r = 0; r < 20; r++) if (row(m, sym('BOARD'), r)) occupied++;
    expect(occupied).toBeGreaterThan(10);
  });

  it('holding left walks pieces to the wall', () => {
    const { m, sym } = boot();
    for (let i = 0; i < 3; i++) drop(m, JOY_LEFT, 40); // slide left, then drop
    let col0 = false;
    for (let r = 0; r < 20; r++) if (row(m, sym('BOARD'), r) & 1) col0 = true;
    expect(col0).toBe(true);
  });

  it('clears full lines and scores them', () => {
    const { m, sym } = boot();
    const BOARD = sym('BOARD');
    // pre-fill the bottom two rows; one lock on top should clear both
    m.bus.writeWord(BOARD + 18 * 2, 0o1777);
    m.bus.writeWord(BOARD + 19 * 2, 0o1777);
    drop(m); // a single piece locks on top and triggers the clear
    expect(bcd(m, sym('LINES'), 3)).toBe(2);
    expect(bcd(m, sym('SCORE'), 6)).toBe(100); // two lines = 100 points
    expect(row(m, BOARD, 19) & 0o1777).not.toBe(0o1777); // the full rows are gone
  });
});
