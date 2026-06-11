import { Machine } from '../src/core/machine';

export const ORG = 0o001000;

/** Build a machine with `words` loaded at ORG, PC=ORG, SP just below the framebuffer. */
export function mk(words: readonly number[]): Machine {
  const m = new Machine();
  m.loadWords(ORG, words);
  m.cpu.regs[7] = ORG;
  m.cpu.regs[6] = 0o060000;
  return m;
}

export function steps(m: Machine, n: number): void {
  for (let i = 0; i < n; i++) m.cpu.step();
}

/** Run until HALT (with a safety budget). */
export function runToHalt(m: Machine, budget = 100000): void {
  m.run(budget);
  if (!m.cpu.halted) throw new Error('program did not halt within budget');
}

export interface Flags {
  n: number;
  z: number;
  v: number;
  c: number;
}

export const flags = (m: Machine): Flags => ({
  n: (m.cpu.psw >> 3) & 1,
  z: (m.cpu.psw >> 2) & 1,
  v: (m.cpu.psw >> 1) & 1,
  c: m.cpu.psw & 1,
});
