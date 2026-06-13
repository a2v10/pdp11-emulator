import { useState } from 'react';
import { Screen } from './Screen';
import { useEmulator } from './useEmulator';
import { JOY_DOWN, JOY_FIRE, JOY_LEFT, JOY_RIGHT } from '../core/constants';
import arkanoidSource from '../../programs/arkanoid.s?raw';
import tetrisSource from '../../programs/tetris.s?raw';

const PROGRAMS = {
  arkanoid: { source: arkanoidSource, hint: '← → — paddle · space / ↑ — launch' },
  tetris: { source: tetrisSource, hint: '← → — move · ↑ / space — rotate · ↓ — drop' },
} as const;
type Tab = keyof typeof PROGRAMS;

const oct = (v: number): string => v.toString(8).padStart(6, '0');

const FLAG_NAMES = ['N', 'Z', 'V', 'C'] as const;
const flagBit = (psw: number, i: number): boolean => (psw & (0o10 >> i)) !== 0;

export function App() {
  const emu = useEmulator();
  const [tab, setTab] = useState<Tab>('arkanoid');
  const [source, setSource] = useState(PROGRAMS.arkanoid.source);
  const { machine, running, frame, view } = emu;
  const cpu = machine.cpu;

  // switch demos: load the program into the editor and machine, but wait
  // for Assemble & Run to actually start it
  const selectTab = (t: Tab): void => {
    if (t === tab) return;
    setTab(t);
    setSource(PROGRAMS[t].source);
    emu.load(PROGRAMS[t].source); // assemble + reset, leaves it stopped
  };

  // drop focus so space/arrows go to the joystick, not the button
  const unfocus = (e: React.MouseEvent<HTMLButtonElement>): void => e.currentTarget.blur();

  // touch joystick: hold a button — hold the bit, like a real stick
  const hold = (mask: number) => ({
    onPointerDown: (e: React.PointerEvent<HTMLButtonElement>): void => {
      e.preventDefault();
      machine.joystick.state |= mask;
      try {
        e.currentTarget.setPointerCapture(e.pointerId);
      } catch {
        // pointer may already be gone; the bit still clears on pointerup/cancel
      }
    },
    onPointerUp: (): void => {
      machine.joystick.state &= ~mask;
    },
    onPointerCancel: (): void => {
      machine.joystick.state &= ~mask;
    },
    onContextMenu: (e: React.MouseEvent): void => e.preventDefault(), // long-press on Android
  });

  const assembleAndRun = (e: React.MouseEvent<HTMLButtonElement>): void => {
    unfocus(e);
    emu.audio.unlock(); // autoplay policy: the context only starts inside a user gesture
    if (emu.load(source)) emu.setRunning(true);
  };

  const status = cpu.halted ? 'HALT' : running ? 'RUN' : cpu.waiting ? 'WAIT' : 'STOP';

  return (
    <div className="app">
      <header>
        <h1>PDP-11</h1>
        <span className={`status status-${status.toLowerCase()}`}>{status}</span>
        <nav className="tabs">
          {(Object.keys(PROGRAMS) as Tab[]).map((t) => (
            <button
              key={t}
              className={t === tab ? 'tab active' : 'tab'}
              onClick={(e) => {
                unfocus(e);
                selectTab(t);
              }}
            >
              {t === 'arkanoid' ? 'Arkanoid' : 'Tetris'}
            </button>
          ))}
        </nav>
      </header>

      <main>
        <section className="left">
          <Screen machine={machine} frame={frame} />
          <div className="controls">
            <button className="primary" onClick={assembleAndRun}>
              Assemble &amp; Run
            </button>
            <button
              onClick={(e) => {
                unfocus(e);
                if (!running) emu.audio.unlock();
                emu.setRunning(!running);
              }}
              disabled={cpu.halted}
            >
              {running ? 'Pause' : 'Resume'}
            </button>
            <button
              onClick={(e) => {
                unfocus(e);
                emu.step();
              }}
              disabled={running}
            >
              Step
            </button>
            <button
              onClick={(e) => {
                unfocus(e);
                emu.stepFrame();
              }}
              disabled={running}
            >
              Frame
            </button>
            <button
              onClick={(e) => {
                unfocus(e);
                emu.setMuted(!emu.muted);
              }}
              aria-label={emu.muted ? 'unmute' : 'mute'}
            >
              {emu.muted ? '🔇' : '🔊'}
            </button>
          </div>
          <div className="touch-controls">
            <button {...hold(JOY_LEFT)} aria-label="left">
              ◀
            </button>
            <button {...hold(JOY_FIRE)} aria-label="fire">
              ●
            </button>
            <button {...hold(JOY_DOWN)} aria-label="down">
              ▼
            </button>
            <button {...hold(JOY_RIGHT)} aria-label="right">
              ▶
            </button>
          </div>
          <div className="hint">{PROGRAMS[tab].hint}</div>

          <table className="registers">
            <tbody>
              <tr>
                {[0, 1, 2, 3].map((i) => (
                  <td key={i}>
                    <b>R{i}</b> {oct(view.regs[i])}
                  </td>
                ))}
              </tr>
              <tr>
                <td>
                  <b>R4</b> {oct(view.regs[4])}
                </td>
                <td>
                  <b>R5</b> {oct(view.regs[5])}
                </td>
                <td>
                  <b>SP</b> {oct(view.regs[6])}
                </td>
                <td>
                  <b>PC</b> {oct(view.regs[7])}
                </td>
              </tr>
              <tr>
                <td colSpan={2}>
                  <b>PSW</b> {oct(view.psw)}{' '}
                  {FLAG_NAMES.map((f, i) => (
                    <span key={f} className={flagBit(view.psw, i) ? 'flag on' : 'flag'}>
                      {f}
                    </span>
                  ))}
                </td>
                <td colSpan={2}>
                  <b>Cycles</b> {cpu.cycles}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section className="right">
          <textarea
            value={source}
            onChange={(e) => setSource(e.target.value)}
            spellCheck={false}
            wrap="off"
          />
          {emu.errors.length > 0 && (
            <div className="errors">
              {emu.errors.map((e, i) => (
                <div key={i}>
                  line {e.line}: {e.message}
                </div>
              ))}
            </div>
          )}
        </section>
      </main>
    </div>
  );
}
