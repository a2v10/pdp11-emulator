import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { assemble } from '../src/asm/assembler';
import { Machine } from '../src/core/machine';
import { FB_BASE, JOY_FIRE, JOY_LEFT, JOY_UP } from '../src/core/constants';

const source = readFileSync(join(__dirname, '../programs/pacman.s'), 'utf8');

// the maze exactly as the assembler sees it
const ART = [...source.matchAll(/\.ASCII \/(.*)\//g)].map((m) => m[1]);
const W = 28;
const H = 31;
const at = (x: number, y: number): string =>
  x < 0 || x >= W || y < 0 || y >= H ? '#' : ART[y][x];
const open = (x: number, y: number): boolean => at(x, y) !== '#';
const inHouse = (x: number, y: number): boolean => y >= 12 && y <= 15 && x >= 10 && x <= 17;

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
  const word = (name: string, off = 0): number => (m.bus.readWord(sym(name) + off) << 16) >> 16;
  const poke = (name: string, v: number, off = 0): void =>
    m.bus.writeWord(sym(name) + off, v & 0xffff);
  for (let i = 0; i < 40; i++) m.runFrame(); // boot: clear, parse, trace, paint
  return { m, r, sym, word, poke };
}

function startGame(m: Machine): void {
  m.joystick.state = JOY_FIRE;
  m.runFrame();
  m.joystick.state = 0;
  for (let i = 0; i < 62; i++) m.runFrame(); // the READY pause
}

const score = (sym: (n: string) => number, m: Machine): number => {
  let v = 0;
  for (let i = 0; i < 6; i++) v = v * 10 + m.bus.readWord(sym('DIGS') + i * 2);
  return v;
};

describe('the maze itself', () => {
  it('is 28x31 with sane characters', () => {
    expect(ART.length).toBe(H);
    for (const row of ART) {
      expect(row.length).toBe(W);
      expect([...row].every((ch) => '#.o- '.includes(ch))).toBe(true);
    }
  });

  it('is left-right symmetric', () => {
    for (let y = 0; y < H; y++)
      for (let x = 0; x < W / 2; x++) expect(at(x, y)).toBe(at(W - 1 - x, y));
  });

  it('has no dead ends: every corridor tile has two ways out', () => {
    for (let y = 0; y < H; y++)
      for (let x = 0; x < W; x++) {
        if (!open(x, y) || inHouse(x, y)) continue;
        let n = 0;
        if (open(x - 1, y) && !inHouse(x - 1, y)) n++;
        if (open(x + 1, y) && !inHouse(x + 1, y)) n++;
        if (open(x, y - 1) && at(x, y - 1) !== '-') n++;
        if (open(x, y + 1) && at(x, y + 1) !== '-') n++;
        if (x === 0 && open(W - 1, y)) n++;
        if (x === W - 1 && open(0, y)) n++;
        expect(n, `tile (${x},${y})`).toBeGreaterThanOrEqual(2);
      }
  });

  it('every dot is reachable from pac start', () => {
    const seen = new Set<string>();
    const stack: [number, number][] = [[13, 23]];
    while (stack.length) {
      const [x, y] = stack.pop()!;
      const k = `${x},${y}`;
      if (seen.has(k) || !open(x, y) || at(x, y) === '-' || inHouse(x, y)) continue;
      seen.add(k);
      stack.push([x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]);
      if (x === 0) stack.push([W - 1, y]);
      if (x === W - 1) stack.push([0, y]);
    }
    for (let y = 0; y < H; y++)
      for (let x = 0; x < W; x++)
        if (at(x, y) === '.' || at(x, y) === 'o')
          expect(seen.has(`${x},${y}`), `(${x},${y})`).toBe(true);
  });
});

describe('pacman boots', () => {
  it('assembles with entry at START', () => {
    const r = assemble(source);
    expect(r.errors).toEqual([]);
    expect(r.entry).toBe(r.symbols.get('START'));
  });

  it('parses the maze, paints walls and dots, and waits for fire', () => {
    const { m, word } = boot();
    const artDots = ART.join('').split('').filter((c) => c === '.' || c === 'o').length;
    expect(word('DOTCNT')).toBe(artDots);
    expect(word('STATE')).toBe(0);
    expect(m.cpu.waiting).toBe(true);
    // the top-left wall tile traces its outer edge at y=16
    expect(m.memory.bytes[FB_BASE + 16 * 64 + 4]).toBe(0xff);
    // the dot at tile (1,1): rows 38..41, bits 6-7 of byte 6
    expect(m.memory.bytes[FB_BASE + 38 * 64 + 6] & 0xc0).toBe(0xc0);
    // squares table: 5*5 = 25
    const { sym } = boot();
    expect(m.bus.readWord(sym('SQT') + 10)).toBe(25);
  });
});

describe('pac himself', () => {
  it('fire starts the game and pac sets off eating to the left', () => {
    const { m, word } = boot();
    const dots0 = word('DOTCNT');
    startGame(m);
    expect(word('STATE')).toBe(2);
    for (let i = 0; i < 40; i++) m.runFrame();
    expect(word('PACX')).toBeLessThan(208);
    expect(word('DOTCNT')).toBeLessThan(dots0);
  });

  it('scores 10 a dot', () => {
    const { m, word, sym } = boot();
    const dots0 = word('DOTCNT');
    startGame(m);
    for (let i = 0; i < 40; i++) m.runFrame();
    expect(score(sym, m)).toBe((dots0 - word('DOTCNT')) * 10);
  });

  it('a buffered up turn takes the first side street', () => {
    const { m, word } = boot();
    startGame(m);
    m.joystick.state = JOY_UP;
    for (let i = 0; i < 80; i++) m.runFrame();
    m.joystick.state = 0;
    expect(word('PACY')).toBeLessThan(368);
  });

  it('the tunnel wraps him around', () => {
    const { m, word, poke } = boot();
    startGame(m);
    poke('PACX', 32);
    poke('PACY', 224);
    poke('PACDIR', 1);
    poke('PACWNT', 1);
    poke('PACMOQ', 1);
    m.joystick.state = JOY_LEFT;
    let widest = 0;
    for (let i = 0; i < 60; i++) {
      m.runFrame();
      widest = Math.max(widest, word('PACX'));
    }
    m.joystick.state = 0;
    expect(widest).toBeGreaterThan(400); // reappeared on the right
  });
});

describe('the ghosts', () => {
  it('pinky leaves the house and hunts', () => {
    const { m, word } = boot();
    startGame(m);
    for (let i = 0; i < 300; i++) m.runFrame();
    expect(word('GST', 2)).toBe(2);
  });

  it('blinky walks off his doorstep', () => {
    const { m, word } = boot();
    startGame(m);
    for (let i = 0; i < 60; i++) m.runFrame();
    const moved = word('GX') !== 208 || word('GY') !== 176;
    expect(moved).toBe(true);
  });

  it('an energizer frightens the pack', () => {
    const { m, word, poke, sym } = boot();
    startGame(m);
    poke('PACX', 32); // two tiles right of the (1,3) energizer
    poke('PACY', 48);
    poke('PACDIR', 1);
    poke('PACWNT', 1);
    poke('PACMOQ', 1);
    m.joystick.state = JOY_LEFT;
    for (let i = 0; i < 12; i++) m.runFrame();
    m.joystick.state = 0;
    expect(word('FRTCNT')).toBeGreaterThan(0);
    expect(word('GST')).toBe(3); // blinky is blue
    expect(m.memory.bytes[sym('MAP') + 3 * 28 + 1]).toBe(0); // the pill is gone
  });

  it('a blue ghost is worth 200 and turns into eyes', () => {
    const { m, word, poke, sym } = boot();
    startGame(m);
    poke('PACX', 32);
    poke('PACY', 48);
    poke('PACMOQ', 0);
    poke('FRTCNT', 300);
    poke('GST', 3);
    poke('GX', 40); // same tile, mid-stride
    poke('GY', 48);
    poke('GDIR', 1);
    const s0 = score(sym, m);
    for (let i = 0; i < 3; i++) m.runFrame();
    expect(word('GST')).toBe(4);
    expect(score(sym, m) - s0).toBeGreaterThanOrEqual(200);
  });

  it('a hunter costs pac a life; the table resets', () => {
    const { m, word, poke } = boot();
    startGame(m);
    poke('PACX', 32);
    poke('PACY', 48);
    poke('PACMOQ', 0);
    poke('FRTCNT', 0);
    poke('GST', 2);
    poke('GX', 40);
    poke('GY', 48);
    poke('GDIR', 1);
    for (let i = 0; i < 4; i++) m.runFrame();
    expect(word('STATE')).toBe(3);
    for (let i = 0; i < 130; i++) m.runFrame();
    expect(word('LIVES')).toBe(2);
    expect(word('PACX')).toBe(208); // back at his post
  });
});

describe('the board', () => {
  it('the last dot clears it and deals a fresh one', () => {
    const { m, word, poke } = boot();
    startGame(m);
    const total = 252;
    expect(word('DOTCNT')).toBe(total);
    poke('DOTCNT', 1); // pretend only the dot to pac's left remains
    for (let i = 0; i < 20; i++) m.runFrame();
    expect(word('STATE')).toBe(4);
    for (let i = 0; i < 130; i++) m.runFrame();
    expect(word('DOTCNT')).toBe(total);
    expect(word('LEVEL')).toBe(2);
    expect(word('PACX')).toBe(208);
  });
});
