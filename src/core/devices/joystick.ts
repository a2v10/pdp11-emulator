import type { Device } from '../bus';
import { JOY_REG } from '../constants';

/**
 * Game controller: one read-only word holding the currently held
 * buttons (JOY_LEFT | JOY_RIGHT | JOY_FIRE). The host UI sets `state`
 * from keydown/keyup; the program polls it once per frame.
 */
export class Joystick implements Device {
  readonly name = 'joystick';
  readonly start = JOY_REG;
  readonly end = JOY_REG + 2;
  state = 0;

  readWord(): number {
    return this.state;
  }

  writeWord(): void {
    // read-only
  }

  reset(): void {
    this.state = 0;
  }
}
