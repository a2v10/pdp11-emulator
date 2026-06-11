import { describe, expect, it } from 'vitest';
import { Machine } from '../src/core/machine';
import { CpuTrap } from '../src/core/trap';
import { JOY_REG, KW11_LKS } from '../src/core/constants';

describe('memory and bus', () => {
  it('word access is little-endian over the same buffer as bytes', () => {
    const m = new Machine();
    m.bus.writeWord(0o1000, 0x1234);
    expect(m.memory.bytes[0o1000]).toBe(0x34);
    expect(m.memory.bytes[0o1001]).toBe(0x12);
    expect(m.bus.readWord(0o1000)).toBe(0x1234);
  });

  it('byte writes land in the right half of the word', () => {
    const m = new Machine();
    m.bus.writeByte(0o1000, 0xaa);
    m.bus.writeByte(0o1001, 0x55);
    expect(m.bus.readWord(0o1000)).toBe(0x55aa);
    expect(m.bus.readByte(0o1001)).toBe(0x55);
  });

  it('word access to an odd address traps', () => {
    const m = new Machine();
    expect(() => m.bus.readWord(0o1001)).toThrow(CpuTrap);
    expect(() => m.bus.writeWord(0o1001, 0)).toThrow(CpuTrap);
  });

  it('access to an unmapped I/O address traps (bus timeout)', () => {
    const m = new Machine();
    expect(() => m.bus.readWord(0o177700)).toThrow(CpuTrap);
  });

  it('mapped device registers answer', () => {
    const m = new Machine();
    m.joystick.state = 5;
    expect(m.bus.readWord(JOY_REG)).toBe(5);
    expect(m.bus.readWord(KW11_LKS)).toBe(0);
  });

  it('onAccess hook observes traffic', () => {
    const m = new Machine();
    const log: string[] = [];
    m.bus.onAccess = (write, addr, value) => log.push(`${write ? 'w' : 'r'} ${addr.toString(8)}=${value}`);
    m.bus.writeWord(0o1000, 7);
    m.bus.readWord(0o1000);
    expect(log).toEqual(['w 1000=7', 'r 1000=7']);
  });
});
