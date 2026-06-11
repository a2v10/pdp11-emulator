/**
 * Thrown by the bus/CPU internals to abort the current instruction;
 * CPU.step() catches it and dispatches through the given vector.
 */
export class CpuTrap extends Error {
  constructor(readonly vector: number) {
    super(`trap through vector ${vector.toString(8)}`);
    this.name = 'CpuTrap';
  }
}
