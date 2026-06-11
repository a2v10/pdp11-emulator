import { describe, expect, it } from 'vitest';
import { assemble } from '../src/asm/assembler';
import { Machine } from '../src/core/machine';

/** Assemble and return emitted words (assumes word-aligned contiguous output). */
function words(src: string): number[] {
  const r = assemble(src);
  expect(r.errors).toEqual([]);
  const out: number[] = [];
  for (const reg of r.regions) {
    for (let a = reg.start; a < reg.end; a += 2) {
      out.push(r.image[a] | (r.image[a + 1] << 8));
    }
  }
  return out;
}

function errorsOf(src: string): string[] {
  return assemble(src).errors.map((e) => e.message);
}

describe('instruction encoding', () => {
  it('immediate and absolute', () => {
    expect(words('MOV #5, R0')).toEqual([0o012700, 5]);
    expect(words('MOV @#177570, R0')).toEqual([0o013700, 0o177570]);
  });

  it('all register-based modes', () => {
    expect(words('MOV R1, R0')).toEqual([0o010100]);
    expect(words('MOV (R1), R0')).toEqual([0o011100]);
    expect(words('MOV @R1, R0')).toEqual([0o011100]);
    expect(words('MOV (R1)+, R0')).toEqual([0o012100]);
    expect(words('MOV @(R1)+, R0')).toEqual([0o013100]);
    expect(words('MOV -(R1), R0')).toEqual([0o014100]);
    expect(words('MOV @-(R1), R0')).toEqual([0o015100]);
    expect(words('MOV 2(R1), R0')).toEqual([0o016100, 2]);
    expect(words('MOV @2(R1), R0')).toEqual([0o017100, 2]);
  });

  it('SP and PC aliases', () => {
    expect(words('MOV R1, -(SP)')).toEqual([0o010146]);
    expect(words('RTS PC')).toEqual([0o000207]);
  });

  it('two extra words follow in src, dst order', () => {
    expect(words('MOV 2(R1), 4(R2)')).toEqual([0o016162, 2, 4]);
    expect(words('MOV #1, @#2000')).toEqual([0o012737, 1, 0o2000]);
  });

  it('byte instructions', () => {
    expect(words('MOVB #200, R0')).toEqual([0o112700, 0o200]);
    expect(words('MOVB #377, (R0)+')).toEqual([0o112720, 0o377]);
    expect(words('TSTB R0')).toEqual([0o105700]);
  });

  it('PC-relative: plain symbol operand', () => {
    const src = `
        MOV X, R0
        HALT
X:      .WORD 4242
`;
    // 1000: 016700, 1002: offset, 1004: HALT, 1006: X
    expect(words(src)).toEqual([0o016700, 2, 0, 0o4242]);
  });

  it('PC-relative deferred: @PTR', () => {
    const src = `
        MOV @PTR, R0
        HALT
PTR:    .WORD 2000
`;
    expect(words(src)).toEqual([0o017700, 2, 0, 0o2000]);
  });

  it('branches forward and backward', () => {
    expect(words('X: BR X')).toEqual([0o000777]); // -1 word
    const src = `
        TST R0
        BEQ DONE
        INC R0
DONE:   HALT
`;
    expect(words(src)).toEqual([0o005700, 0o001401, 0o005200, 0]);
  });

  it('branch aliases BLO/BHIS', () => {
    expect(words('X: BLO X')).toEqual([0o103777]);
    expect(words('X: BHIS X')).toEqual([0o103377]);
  });

  it('SOB encodes backward word count', () => {
    const src = `
        MOV #64., R1
LOOP:   MOVB #377, (R0)+
        SOB R1, LOOP
`;
    expect(words(src)).toEqual([0o012701, 64, 0o112720, 0o377, 0o077103]);
  });

  it('JSR / TRAP / EMT / condition codes', () => {
    expect(words('JSR PC, @#2000')).toEqual([0o004737, 0o2000]);
    expect(words('TRAP 7')).toEqual([0o104407]);
    expect(words('EMT')).toEqual([0o104000]);
    expect(words('SEC')).toEqual([0o000261]);
    expect(words('CLC')).toEqual([0o000241]);
    expect(words('NOP')).toEqual([0o000240]);
  });
});

describe('directives and expressions', () => {
  it('.WORD with expressions, octal default, trailing dot decimal', () => {
    expect(words('.WORD 100, 64., 10+5')).toEqual([0o100, 64, 0o15]);
  });

  it('symbols via assignment', () => {
    expect(words('FB = 60000\n MOV #FB+100, R0')).toEqual([0o012700, 0o60100]);
  });

  it('char literal and negative immediate', () => {
    expect(words("MOV #'A, R0")).toEqual([0o012700, 65]);
    expect(words('MOV #-1, R0')).toEqual([0o012700, 0o177777]);
  });

  it('location counter in expressions', () => {
    const r = assemble('X: .WORD .');
    expect(r.errors).toEqual([]);
    expect(r.image[0o1000] | (r.image[0o1001] << 8)).toBe(0o1000);
  });

  it('. = sets the location counter', () => {
    const r = assemble('. = 2000\nHALT');
    expect(r.errors).toEqual([]);
    expect(r.regions).toEqual([{ start: 0o2000, end: 0o2002 }]);
    expect(r.entry).toBe(0o2000);
  });

  it('.BYTE, .EVEN alignment', () => {
    const r = assemble('.BYTE 1, 2, 3\n.EVEN\nHALT');
    expect(r.errors).toEqual([]);
    expect(Array.from(r.image.slice(0o1000, 0o1003))).toEqual([1, 2, 3]);
    expect(r.image[0o1004] | (r.image[0o1005] << 8)).toBe(0); // HALT after .EVEN
    expect(r.symbols.size).toBe(0);
  });

  it('.ASCII and .ASCIZ keep original case', () => {
    const r = assemble('.ASCII /Hi;/');
    expect(r.errors).toEqual([]);
    expect(Array.from(r.image.slice(0o1000, 0o1003))).toEqual([72, 105, 59]);
    const z = assemble('.ASCIZ /A/');
    expect(Array.from(z.image.slice(0o1000, 0o1002))).toEqual([65, 0]);
  });

  it('.BLKW reserves without emitting', () => {
    const src = `
A:      .BLKW 4
B:      HALT
`;
    const r = assemble(src);
    expect(r.errors).toEqual([]);
    expect(r.symbols.get('B')! - r.symbols.get('A')!).toBe(8);
    expect(r.regions).toEqual([{ start: 0o1010, end: 0o1012 }]); // only HALT emitted
  });

  it('labels, symbols and lineMap come out', () => {
    const src = `START:  MOV #5, R0
        HALT`;
    const r = assemble(src);
    expect(r.symbols.get('START')).toBe(0o1000);
    expect(r.lineMap.get(0o1000)).toBe(1);
    expect(r.lineMap.get(0o1004)).toBe(2);
    expect(r.entry).toBe(0o1000);
  });

  it('comments are ignored', () => {
    expect(words('MOV #5, R0 ; load five')).toEqual([0o012700, 5]);
  });
});

describe('errors', () => {
  it('undefined symbol', () => {
    expect(errorsOf('MOV #NOPE, R0')[0]).toMatch(/undefined symbol 'NOPE'/);
  });

  it('digit 8/9 in octal', () => {
    expect(errorsOf('MOV #18, R0')[0]).toMatch(/digit 8 or 9/);
  });

  it('unknown instruction', () => {
    expect(errorsOf('MUL R0, R1')[0]).toMatch(/unknown instruction 'MUL'/);
  });

  it('wrong operand count', () => {
    expect(errorsOf('MOV R0')[0]).toMatch(/expects 2 operand/);
  });

  it('branch out of range', () => {
    const src = `
        BR FAR
        . = 2000
FAR:    HALT
`;
    expect(errorsOf(src)[0]).toMatch(/branch out of range/);
  });

  it('redefined label', () => {
    expect(errorsOf('X: HALT\nX: HALT')[0]).toMatch(/redefined/);
  });
});

describe('integration: source to running machine', () => {
  it('assembles and runs the framebuffer fill', () => {
    const src = `
; fill the first pixel row of the screen
FB      = 60000
        . = 1000
START:  MOV #FB, R0
        MOV #64., R1
LOOP:   MOVB #377, (R0)+
        SOB R1, LOOP
        HALT
        .END START
`;
    const r = assemble(src);
    expect(r.errors).toEqual([]);
    expect(r.entry).toBe(0o1000);

    const m = new Machine();
    m.loadImage(r);
    m.cpu.regs[7] = r.entry;
    m.cpu.regs[6] = 0o060000;
    m.run(100000);
    expect(m.cpu.halted).toBe(true);
    for (let i = 0; i < 64; i++) expect(m.memory.bytes[0o060000 + i]).toBe(0xff);
    expect(m.memory.bytes[0o060000 + 64]).toBe(0);
  });

  it('interrupt-driven program from source: clock handler counts ticks', () => {
    const src = `
LKS     = 177546
        . = 100          ; clock interrupt vector
        .WORD TICK, 340
        . = 1000
START:  MOV #100, @#LKS  ; enable clock interrupts
        WAIT
        HALT
TICK:   INC R0
        RTI
`;
    const r = assemble(src);
    expect(r.errors).toEqual([]);

    const m = new Machine();
    m.loadImage(r);
    m.cpu.regs[7] = r.symbols.get('START')!;
    m.cpu.regs[6] = 0o060000;
    for (let i = 0; i < 5; i++) m.cpu.step(); // MOV; WAIT; idle
    m.kw11.tick();
    m.run(1000);
    expect(m.cpu.halted).toBe(true);
    expect(m.cpu.regs[0]).toBe(1);
  });
});
