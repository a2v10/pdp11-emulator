import { useState } from 'react';
import { Screen } from './Screen';
import { useEmulator } from './useEmulator';
import demoSource from '../../programs/arkanoid.s?raw';

const oct = (v: number): string => v.toString(8).padStart(6, '0');

const FLAG_NAMES = ['N', 'Z', 'V', 'C'] as const;
const flagBit = (psw: number, i: number): boolean => (psw & (0o10 >> i)) !== 0;

export function App() {
  const emu = useEmulator();
  const [source, setSource] = useState(demoSource);
  const { machine, running, frame, view } = emu;
  const cpu = machine.cpu;

  // drop focus so space/arrows go to the joystick, not the button
  const unfocus = (e: React.MouseEvent<HTMLButtonElement>): void => e.currentTarget.blur();

  const assembleAndRun = (e: React.MouseEvent<HTMLButtonElement>): void => {
    unfocus(e);
    if (emu.load(source)) emu.setRunning(true);
  };

  const status = cpu.halted ? 'HALT' : running ? 'RUN' : cpu.waiting ? 'WAIT' : 'STOP';

  return (
    <div className="app">
      <header>
        <h1>PDP-11</h1>
        <span className={`status status-${status.toLowerCase()}`}>{status}</span>
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
          </div>
          <div className="hint">← → — paddle · space / ↑ — launch</div>

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
