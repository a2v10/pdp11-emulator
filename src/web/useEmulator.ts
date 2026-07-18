import { useCallback, useEffect, useRef, useState } from 'react';
import { Machine } from '../core/machine';
import { CYCLES_PER_FRAME, JOY_DOWN, JOY_FIRE, JOY_LEFT, JOY_RIGHT, JOY_UP } from '../core/constants';
import { assemble, AsmError } from '../asm/assembler';
import { SpeakerAudio } from './audio';

export interface RegsView {
  regs: number[];
  psw: number;
}

/**
 * Owns the Machine and the emulation loop. The machine itself is mutable
 * and lives outside React; `frame` is a counter bumped once per rendered
 * frame so dependent components (screen, register panel) re-render.
 */
export function useEmulator() {
  const [machine] = useState(() => new Machine());
  const [audio] = useState(() => new SpeakerAudio());
  const [errors, setErrors] = useState<AsmError[]>([]);
  const [running, setRunning] = useState(false);
  const [muted, setMuted] = useState(false);
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    audio.muted = muted;
  }, [audio, muted]);

  const bump = useCallback(() => setFrame((f) => f + 1), []);

  /** Assemble and load; returns true on success. */
  const load = useCallback(
    (source: string): boolean => {
      setRunning(false);
      const r = assemble(source);
      setErrors(r.errors);
      if (r.errors.length > 0) return false;
      machine.reset();
      machine.memory.bytes.fill(0);
      machine.loadImage(r);
      machine.cpu.regs[7] = r.entry;
      machine.cpu.regs[6] = 0o060000;
      bump();
      return true;
    },
    [machine, bump],
  );

  // Register snapshot taken mid-frame, while the interrupt handler is
  // actually working — at the frame boundary the CPU always idles in WAIT
  // and the panel would show the same PC forever.
  const midFrame = useRef<RegsView>({ regs: [0, 0, 0, 0, 0, 0, 0, 0], psw: 0 });

  // emulation loop: paced by real time at 60 machine frames per second,
  // whatever the display refresh rate (phones are often 90/120 Hz)
  useEffect(() => {
    if (!running) return;
    machine.speaker.events.length = 0; // stale transitions from stepping
    let acc = 0;
    let last = -1;
    let raf = requestAnimationFrame(function loop(ts) {
      if (last < 0) last = ts;
      acc += ts - last;
      last = ts;
      if (acc > 100) acc = 100; // hidden tab: don't fast-forward
      let ran = false;
      while (acc >= 1000 / 60 && !machine.cpu.halted) {
        acc -= 1000 / 60;
        const startCycle = machine.cpu.cycles;
        machine.kw11.tick();
        // run a random slice into the handler, peek at the registers, finish the frame
        const used = machine.run(64 + ((Math.random() * 1024) | 0));
        midFrame.current = { regs: Array.from(machine.cpu.regs), psw: machine.cpu.psw };
        machine.run(CYCLES_PER_FRAME - used);
        audio.pushFrame(machine.speaker.events, startCycle);
        machine.speaker.events.length = 0;
        ran = true;
      }
      if (ran) bump();
      if (machine.cpu.halted) {
        setRunning(false);
        return;
      }
      raf = requestAnimationFrame(loop);
    });
    return () => cancelAnimationFrame(raf);
  }, [running, machine, bump, audio]);

  // keyboard -> joystick
  useEffect(() => {
    const bit = (e: KeyboardEvent): number => {
      switch (e.key) {
        case 'ArrowLeft': return JOY_LEFT;
        case 'ArrowRight': return JOY_RIGHT;
        case ' ': return JOY_FIRE;
        case 'ArrowUp': return JOY_UP;
        case 'ArrowDown': return JOY_DOWN;
        default: return 0;
      }
    };
    const down = (e: KeyboardEvent): void => {
      if ((e.target as HTMLElement | null)?.tagName === 'TEXTAREA') return;
      const b = bit(e);
      if (b) {
        machine.joystick.state |= b;
        e.preventDefault();
      }
    };
    const up = (e: KeyboardEvent): void => {
      const b = bit(e);
      if (b) {
        machine.joystick.state &= ~b;
        e.preventDefault(); // space on keyup would "click" a focused button
      }
    };
    window.addEventListener('keydown', down);
    window.addEventListener('keyup', up);
    return () => {
      window.removeEventListener('keydown', down);
      window.removeEventListener('keyup', up);
    };
  }, [machine]);

  const step = useCallback(() => {
    machine.cpu.step();
    bump();
  }, [machine, bump]);

  const stepFrame = useCallback(() => {
    machine.runFrame();
    bump();
  }, [machine, bump]);

  // what the register panel shows: a mid-frame snapshot while running,
  // the true current state when paused/stepping
  const view: RegsView = running
    ? midFrame.current
    : { regs: Array.from(machine.cpu.regs), psw: machine.cpu.psw };

  return { machine, audio, errors, running, setRunning, muted, setMuted, load, step, stepFrame, frame, view };
}
