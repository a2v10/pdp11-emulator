import { CYCLES_PER_FRAME } from '../core/constants';

const FRAME_SEC = 1 / 60;
const GAIN = 0.18;
const LEAD_MIN = 0.02; // resync when the schedule falls this close to "now"
const LEAD_RESYNC = 0.06; // where a (re)started stream begins: rides out rAF jank
const LEAD_MAX = 0.25; // drop frames that would queue further ahead than this
const IDLE_FRAMES = 30; // keep feeding silence this long before pausing the stream

/**
 * Turns the speaker's (cycle, level) transitions into sound. Every
 * emulated frame becomes one AudioBuffer scheduled on a back-to-back
 * timeline. A one-pole high-pass strips the DC component — a real cone
 * held at +1 goes silent too.
 */
export class SpeakerAudio {
  muted = false;
  private ctx: AudioContext | null = null;
  private next = 0; // audio-context time where the next frame buffer starts
  private level = 0;
  private idle = 0; // consecutive silent frames
  private hpX = 0;
  private hpY = 0;

  /** Create/resume the AudioContext. Must be called from a user gesture. */
  unlock(): void {
    if (this.ctx === null) this.ctx = new AudioContext();
    if (this.ctx.state === 'suspended') void this.ctx.resume();
  }

  /**
   * One emulated frame: `events` are the transitions stamped within
   * [startCycle, startCycle + CYCLES_PER_FRAME); the tail level persists.
   */
  pushFrame(events: readonly number[], startCycle: number): void {
    const ctx = this.ctx;
    const last = events.length > 0 ? events[events.length - 1] : this.level;
    if (ctx === null || ctx.state !== 'running' || this.muted) {
      this.level = last;
      this.hpY = 0;
      return;
    }
    // Silent frame with the cone at rest: keep the stream fed for a
    // while (a resync between every two notes would crackle), then pause.
    if (events.length === 0 && this.level === 0 && Math.abs(this.hpY) < 1e-4) {
      if (++this.idle > IDLE_FRAMES) return;
    } else {
      this.idle = 0;
    }

    const n = Math.round(ctx.sampleRate * FRAME_SEC);
    const buf = ctx.createBuffer(1, n, ctx.sampleRate);
    const out = buf.getChannelData(0);
    const perCycle = n / CYCLES_PER_FRAME;
    let at = 0;
    let lv = this.level;
    for (let e = 0; e < events.length; e += 2) {
      let upTo = Math.floor((events[e] - startCycle) * perCycle);
      if (upTo < at) upTo = at;
      if (upTo > n) upTo = n;
      out.fill(lv, at, upTo);
      at = upTo;
      lv = events[e + 1];
    }
    out.fill(lv, at, n);
    this.level = lv;
    for (let i = 0; i < n; i++) {
      const x = out[i];
      const y = x - this.hpX + 0.995 * this.hpY;
      this.hpX = x;
      this.hpY = y;
      out[i] = y * GAIN;
    }

    const now = ctx.currentTime;
    if (this.next < now + LEAD_MIN) this.next = now + LEAD_RESYNC; // (re)sync with a jitter buffer
    if (this.next > now + LEAD_MAX) return; // tab jank pushed us ahead: drop the frame
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    src.start(this.next);
    this.next += FRAME_SEC;
  }
}
