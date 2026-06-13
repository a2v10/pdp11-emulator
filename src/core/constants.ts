// Memory map (octal, byte addresses):
//
//   000000..000377  interrupt/trap vectors
//   000400..057777  RAM: code, data, stack
//   060000..157777  framebuffer, 512x512 @ 1 bpp, 64 bytes per row
//   160000..177777  I/O page (device registers)

export const MEM_SIZE_BYTES = 0o200000; // 65536

export const FB_BASE = 0o060000;
export const FB_BYTES = 0o100000; // 32768
export const IO_BASE = 0o160000;

export const SCREEN_WIDTH = 512;
export const SCREEN_HEIGHT = 512;
export const FB_BYTES_PER_ROW = SCREEN_WIDTH / 8; // 64; pixel (x,y) lives at FB_BASE + (y << 6) + (x >> 3), bit x & 7

// Trap vectors
export const VEC_ODD = 0o004; // odd word address, bus timeout, illegal register-mode JMP/JSR
export const VEC_RESERVED = 0o010; // reserved instruction
export const VEC_BPT = 0o014;
export const VEC_IOT = 0o020;
export const VEC_EMT = 0o030;
export const VEC_TRAP = 0o034;
export const VEC_CLOCK = 0o100; // KW11 line clock, priority 6

// Device registers
export const KW11_LKS = 0o177546; // line clock status: bit 6 = interrupt enable, bit 7 = monitor flag
export const JOY_REG = 0o177570; // joystick state, read-only
export const SPK_REG = 0o177544; // speaker: bit 0 is the cone position, Spectrum-style

export const JOY_LEFT = 1;
export const JOY_RIGHT = 2;
export const JOY_FIRE = 4;
export const JOY_DOWN = 0o10; // bit 3 — soft drop (Tetris); unused by Arkanoid

// ~1 MHz machine at 60 frames per second
export const CYCLES_PER_FRAME = 16667;
