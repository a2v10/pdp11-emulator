import { DEFS, InstrDef } from '../core/instructions';

/**
 * Two-pass assembler for a MACRO-11 subset.
 *
 * Supported:
 *   labels (LABEL:), assignment (SYM = expr), location counter (. = expr)
 *   instructions from the programmer's card (DEFS), incl. BHIS/BLO aliases
 *   condition-code ops (NOP, CLC, SEC, ...)
 *   directives: .WORD .BYTE .ASCII .ASCIZ .BLKW .BLKB .EVEN .END
 *     (.ASCII maps box-drawing characters to their code page 437 codes)
 *   expressions: octal by default, trailing dot = decimal ("64."),
 *     'c char literal, symbols, ".", operators + - * / & ! evaluated
 *     left to right (no precedence — just like MACRO-11), <> for grouping
 *   addressing: Rn (Rn) (Rn)+ @(Rn)+ -(Rn) @-(Rn) X(Rn) @X(Rn)
 *     #expr @#expr expr (PC-relative) @expr, registers R0..R7, SP, PC
 *   comments: ; to end of line
 *
 * The default location counter is 001000.
 */

export interface AsmError {
  line: number;
  message: string;
}

export interface AsmResult {
  /** Full 64K image; only bytes inside `regions` are meaningful. */
  image: Uint8Array;
  regions: { start: number; end: number }[];
  symbols: Map<string, number>;
  /** address -> source line (1-based) — the debugger's source map. */
  lineMap: Map<number, number>;
  /** Address to start execution at (first emitted statement, or .END arg). */
  entry: number;
  errors: AsmError[];
}

const MNEMONICS = new Map<string, InstrDef>();
for (const d of DEFS) if (d.fmt !== 'cc') MNEMONICS.set(d.name, d);

const ALIASES: Record<string, string> = { BHIS: 'BCC', BLO: 'BCS' };

/** Condition-code ops assemble to fixed words. */
const CC_OPS: Record<string, number> = {
  NOP: 0o000240,
  CLC: 0o000241,
  CLV: 0o000242,
  CLZ: 0o000244,
  CLN: 0o000250,
  CCC: 0o000257,
  SEC: 0o000261,
  SEV: 0o000262,
  SEZ: 0o000264,
  SEN: 0o000270,
  SCC: 0o000277,
};

const REGS: Record<string, number> = {
  R0: 0, R1: 1, R2: 2, R3: 3, R4: 4, R5: 5, R6: 6, R7: 7, SP: 6, PC: 7,
};

// ---- expressions ----

type Tok = number | string; // number = literal value; string = symbol or operator

interface Ctx {
  symbols: Map<string, number>;
  lc: number;
  err: (msg: string) => void;
}

const TOKEN_RE = /([0-9]+\.?)|'(.)|([A-Z$][A-Z0-9$.]*)|(\.)|([-+*/&!<>])/y;

function tokenize(src: string, err: (m: string) => void): Tok[] {
  const toks: Tok[] = [];
  let i = 0;
  while (i < src.length) {
    if (src[i] === ' ' || src[i] === '\t') {
      i++;
      continue;
    }
    TOKEN_RE.lastIndex = i;
    const m = TOKEN_RE.exec(src);
    if (!m) {
      err(`bad character '${src[i]}' in expression`);
      return toks;
    }
    i = TOKEN_RE.lastIndex;
    if (m[1] !== undefined) {
      const t = m[1];
      if (t.endsWith('.')) {
        toks.push(parseInt(t.slice(0, -1), 10));
      } else if (/[89]/.test(t)) {
        err(`digit 8 or 9 in octal number '${t}' (use a trailing dot for decimal)`);
        toks.push(0);
      } else {
        toks.push(parseInt(t, 8));
      }
    } else if (m[2] !== undefined) {
      toks.push(m[2].charCodeAt(0) & 0xff);
    } else if (m[3] !== undefined) {
      toks.push(m[3]);
    } else if (m[4] !== undefined) {
      toks.push('.');
    } else {
      toks.push(m[5]);
    }
  }
  return toks;
}

/** Evaluate left-to-right, MACRO-11 style: no operator precedence. */
function evalExpr(src: string, ctx: Ctx): number {
  const toks = tokenize(src, ctx.err);
  let i = 0;

  const atom = (): number => {
    const t = toks[i++];
    if (t === undefined) {
      ctx.err('unexpected end of expression');
      return 0;
    }
    if (t === '+') return atom();
    if (t === '-') return -atom();
    if (t === '<') {
      const v = run();
      if (toks[i] === '>') i++;
      else ctx.err("missing '>'");
      return v;
    }
    if (typeof t === 'number') return t;
    if (t === '.') return ctx.lc;
    if (typeof t === 'string' && /^[A-Z$]/.test(t)) {
      const v = ctx.symbols.get(t);
      if (v === undefined) {
        ctx.err(`undefined symbol '${t}'`);
        return 0;
      }
      return v;
    }
    ctx.err(`unexpected '${t}' in expression`);
    return 0;
  };

  const run = (): number => {
    let v = atom();
    while (i < toks.length && typeof toks[i] === 'string' && '+-*/&!'.includes(toks[i] as string)) {
      const op = toks[i++] as string;
      const b = atom();
      switch (op) {
        case '+': v += b; break;
        case '-': v -= b; break;
        case '*': v *= b; break;
        case '/':
          if (b === 0) {
            ctx.err('division by zero');
          } else {
            v = (v / b) | 0;
          }
          break;
        case '&': v &= b; break;
        default: v |= b; // '!' is OR in MACRO-11
      }
    }
    return v;
  };

  const v = run();
  if (i < toks.length && toks[i] !== '>') ctx.err(`unexpected '${toks[i]}' after expression`);
  return v & 0xffff;
}

/** Signed 16-bit difference, for branch/relative arithmetic. */
const sdiff = (a: number, b: number): number => ((a - b) << 16) >> 16;

// ---- operands ----

interface Operand {
  spec: number; // 6-bit mode|reg
  expr: string | null; // expression for the extra word, if any
  rel: boolean; // extra word is a PC-relative displacement
}

function parseOperand(s: string, err: (m: string) => void): Operand {
  s = s.trim();
  let deferred = 0;
  if (s.startsWith('@')) {
    deferred = 0o10;
    s = s.slice(1).trim();
  }
  if (s.startsWith('#')) {
    // #expr immediate (27) / @#expr absolute (37)
    return { spec: 0o27 | deferred, expr: s.slice(1), rel: false };
  }
  let m = /^-\(\s*(R[0-7]|SP|PC)\s*\)$/.exec(s);
  if (m) return { spec: 0o40 | deferred | REGS[m[1]], expr: null, rel: false };
  m = /^\(\s*(R[0-7]|SP|PC)\s*\)\+$/.exec(s);
  if (m) return { spec: 0o20 | deferred | REGS[m[1]], expr: null, rel: false };
  m = /^\(\s*(R[0-7]|SP|PC)\s*\)$/.exec(s);
  if (m) {
    // (Rn) is mode 1; @(Rn) means @0(Rn), i.e. mode 7 with zero index
    return deferred
      ? { spec: 0o70 | REGS[m[1]], expr: '0', rel: false }
      : { spec: 0o10 | REGS[m[1]], expr: null, rel: false };
  }
  if (REGS[s] !== undefined) {
    // Rn is mode 0; @Rn is mode 1
    return { spec: (deferred ? 0o10 : 0) | REGS[s], expr: null, rel: false };
  }
  m = /^(.+)\(\s*(R[0-7]|SP|PC)\s*\)$/.exec(s);
  if (m) return { spec: 0o60 | deferred | REGS[m[2]], expr: m[1], rel: false };
  if (s.length === 0) {
    err('missing operand');
    return { spec: 0, expr: null, rel: false };
  }
  // bare expression: PC-relative (67) / @expr relative deferred (77)
  return { spec: 0o67 | deferred, expr: s, rel: true };
}

const expectReg = (s: string, err: (m: string) => void): number => {
  const r = REGS[s.trim()];
  if (r === undefined) {
    err(`expected a register, got '${s.trim()}'`);
    return 0;
  }
  return r;
};

// ---- statements ----

type Kind =
  | 'empty'
  | 'instr'
  | 'org'
  | 'assign'
  | 'word'
  | 'byte'
  | 'ascii'
  | 'blk'
  | 'even'
  | 'end';

interface Stmt {
  line: number;
  kind: Kind;
  addr: number;
  size: number;
  // instr
  def?: InstrDef;
  literal?: number; // cc ops
  ops?: Operand[];
  regNum?: number;
  targetExpr?: string;
  trapExpr?: string;
  // directives
  exprs?: string[];
  strBytes?: number[];
  name?: string; // assign
  argExpr?: string; // org / assign / blk / end
  blkUnit?: number;
}

/** Strip a trailing comment, respecting 'c char literals. */
function stripComment(line: string): string {
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === "'") {
      i++; // char literal consumes the next character
    } else if (ch === ';') {
      return line.slice(0, i);
    }
  }
  return line;
}

const LABEL_RE = /^\s*([A-Z$][A-Z0-9$.]*):/;

export function assemble(source: string): AsmResult {
  const errors: AsmError[] = [];
  const symbols = new Map<string, number>();
  const stmts: Stmt[] = [];
  const lines = source.split(/\r?\n/);
  let lc = 0o001000;

  // ---- pass 1: parse, size, place labels ----

  for (let idx = 0; idx < lines.length; idx++) {
    const line = idx + 1;
    const err = (message: string): void => {
      errors.push({ line, message });
    };
    const ctx: Ctx = { symbols, lc, err };

    const rawLine = lines[idx];
    const upperLine = rawLine.toUpperCase();

    // labels (there may be several)
    let pos = 0;
    for (;;) {
      const m = LABEL_RE.exec(upperLine.slice(pos));
      if (!m) break;
      if (symbols.has(m[1])) err(`label '${m[1]}' redefined`);
      symbols.set(m[1], lc);
      pos += m[0].length;
    }

    const bodyRaw = rawLine.slice(pos).trim(); // original case, comment intact
    // .ASCII/.ASCIZ go first: the payload may contain ';', so the comment
    // can only be stripped after the closing delimiter
    const asciiMatch = /^\.(ASCII|ASCIZ)\b\s*(.*)$/i.exec(bodyRaw);
    const body = asciiMatch ? '' : stripComment(bodyRaw).toUpperCase().trim();

    const st: Stmt = { line, kind: 'empty', addr: lc, size: 0 };
    stmts.push(st);

    if (asciiMatch) {
      st.kind = 'ascii';
      st.strBytes = parseStringPayload(asciiMatch[2].trim(), err);
      if (asciiMatch[1].toUpperCase() === 'ASCIZ') st.strBytes.push(0);
      st.size = st.strBytes.length;
      lc = (lc + st.size) & 0xffff;
      continue;
    }

    if (body.length === 0) continue;

    let m: RegExpExecArray | null;

    if ((m = /^\.\s*=\s*(.+)$/.exec(body))) {
      // . = expr  (set location counter)
      st.kind = 'org';
      st.argExpr = m[1];
      lc = evalExpr(m[1], ctx);
      continue;
    }

    if ((m = /^([A-Z$][A-Z0-9$.]*)\s*=\s*(.+)$/.exec(body))) {
      st.kind = 'assign';
      st.name = m[1];
      st.argExpr = m[2];
      symbols.set(m[1], evalExpr(m[2], ctx));
      continue;
    }

    if ((m = /^\.(WORD|BYTE|BLKW|BLKB|EVEN|END)\b\s*(.*)$/.exec(body))) {
      const dir = m[1];
      const args = m[2];
      switch (dir) {
        case 'WORD':
          st.kind = 'word';
          st.exprs = args.length > 0 ? args.split(',') : [];
          st.size = 2 * st.exprs.length;
          if (lc & 1) err('.WORD at odd address (use .EVEN)');
          break;
        case 'BYTE':
          st.kind = 'byte';
          st.exprs = args.length > 0 ? args.split(',') : [];
          st.size = st.exprs.length;
          break;
        case 'BLKW':
        case 'BLKB':
          st.kind = 'blk';
          st.blkUnit = dir === 'BLKW' ? 2 : 1;
          st.argExpr = args;
          st.size = st.blkUnit * evalExpr(args.length > 0 ? args : '1', ctx);
          break;
        case 'EVEN':
          st.kind = 'even';
          st.size = lc & 1;
          break;
        default: // END
          st.kind = 'end';
          st.argExpr = args.length > 0 ? args : undefined;
          break;
      }
      lc = (lc + st.size) & 0xffff;
      continue;
    }

    // instruction
    if ((m = /^([A-Z][A-Z0-9]*)\s*(.*)$/.exec(body))) {
      const mn = m[1];
      const opsStr = m[2].trim();
      const operands = opsStr.length > 0 ? opsStr.split(',') : [];
      st.kind = 'instr';
      st.size = 2;

      const ccWord = CC_OPS[mn];
      if (ccWord !== undefined) {
        st.literal = ccWord;
        if (operands.length !== 0) err(`${mn} takes no operands`);
        if (lc & 1) err('instruction at odd address (use .EVEN)');
        lc = (lc + st.size) & 0xffff;
        continue;
      }

      const d = MNEMONICS.get(ALIASES[mn] ?? mn);
      if (!d) {
        err(`unknown instruction '${mn}'`);
        st.kind = 'empty';
        st.size = 0;
        continue;
      }
      st.def = d;

      const want = (n: number): boolean => {
        if (operands.length !== n) {
          err(`${mn} expects ${n} operand(s), got ${operands.length}`);
          return false;
        }
        return true;
      };

      switch (d.fmt) {
        case 'none':
          want(0);
          break;
        case 'reg':
          if (want(1)) st.regNum = expectReg(operands[0], err);
          break;
        case 'single':
          if (want(1)) st.ops = [parseOperand(operands[0], err)];
          break;
        case 'double':
          if (want(2)) st.ops = [parseOperand(operands[0], err), parseOperand(operands[1], err)];
          break;
        case 'regsrc':
          if (want(2)) {
            st.regNum = expectReg(operands[0], err);
            st.ops = [parseOperand(operands[1], err)];
          }
          break;
        case 'branch':
          if (want(1)) st.targetExpr = operands[0];
          break;
        case 'sob':
          if (want(2)) {
            st.regNum = expectReg(operands[0], err);
            st.targetExpr = operands[1];
          }
          break;
        case 'trapn':
          if (operands.length > 1) err(`${mn} expects at most one operand`);
          st.trapExpr = operands[0];
          break;
        case 'cc':
          break; // unreachable: ccop is not in MNEMONICS
      }

      if (st.ops) for (const op of st.ops) if (op.expr !== null) st.size += 2;
      if (lc & 1) err('instruction at odd address (use .EVEN)');
      lc = (lc + st.size) & 0xffff;
      continue;
    }

    err(`cannot parse: '${body}'`);
  }

  // ---- pass 2: emit ----

  const image = new Uint8Array(0x10000);
  const marks: { start: number; end: number }[] = [];
  const lineMap = new Map<number, number>();
  let entry = -1;

  const emitByte = (addr: number, v: number): void => {
    image[addr & 0xffff] = v & 0xff;
    marks.push({ start: addr & 0xffff, end: (addr & 0xffff) + 1 });
    if (entry < 0) entry = addr & 0xffff;
  };
  const emitWord = (addr: number, v: number): void => {
    emitByte(addr, v);
    emitByte(addr + 1, v >> 8);
  };

  for (const st of stmts) {
    const err = (message: string): void => {
      errors.push({ line: st.line, message });
    };
    const ctx: Ctx = { symbols, lc: st.addr, err };

    switch (st.kind) {
      case 'empty':
      case 'org':
      case 'assign':
      case 'even':
      case 'blk':
        break;

      case 'end':
        if (st.argExpr !== undefined) entry = evalExpr(st.argExpr, ctx);
        break;

      case 'word': {
        lineMap.set(st.addr, st.line);
        let a = st.addr;
        for (const e of st.exprs!) {
          emitWord(a, evalExpr(e, ctx));
          a += 2;
        }
        break;
      }

      case 'byte': {
        lineMap.set(st.addr, st.line);
        let a = st.addr;
        for (const e of st.exprs!) {
          emitByte(a, evalExpr(e, ctx));
          a += 1;
        }
        break;
      }

      case 'ascii': {
        lineMap.set(st.addr, st.line);
        let a = st.addr;
        for (const b of st.strBytes!) emitByte(a++, b);
        break;
      }

      case 'instr': {
        lineMap.set(st.addr, st.line);
        const d = st.def;
        let w: number;

        if (st.literal !== undefined) {
          w = st.literal;
        } else if (!d) {
          break;
        } else {
          switch (d.fmt) {
            case 'none':
              w = d.pattern;
              break;
            case 'reg':
              w = d.pattern | (st.regNum ?? 0);
              break;
            case 'single':
              w = d.pattern | (st.ops?.[0].spec ?? 0);
              break;
            case 'double':
              w = d.pattern | ((st.ops?.[0].spec ?? 0) << 6) | (st.ops?.[1].spec ?? 0);
              break;
            case 'regsrc':
              w = d.pattern | ((st.regNum ?? 0) << 6) | (st.ops?.[0].spec ?? 0);
              break;
            case 'branch': {
              const target = evalExpr(st.targetExpr ?? '0', ctx);
              const diff = sdiff(target, st.addr + 2);
              if (diff & 1) err('branch to an odd address');
              const off = diff >> 1;
              if (off < -128 || off > 127) err(`branch out of range (${off} words)`);
              w = d.pattern | (off & 0xff);
              break;
            }
            case 'sob': {
              const target = evalExpr(st.targetExpr ?? '0', ctx);
              const back = sdiff(st.addr + 2, target);
              if (back & 1) err('SOB target at an odd address');
              const n = back >> 1;
              if (n < 0 || n > 63) err(`SOB target out of range (${n} words back, max 63)`);
              w = d.pattern | ((st.regNum ?? 0) << 6) | (n & 0o77);
              break;
            }
            case 'trapn': {
              const n = st.trapExpr !== undefined ? evalExpr(st.trapExpr, ctx) : 0;
              if (n > 0o377) err('trap number out of range (0..377)');
              w = d.pattern | (n & 0o377);
              break;
            }
            default:
              w = d.pattern;
          }
        }

        emitWord(st.addr, w);

        // extra words: source operand first, then destination — the same
        // order the CPU fetches them in
        let ea = st.addr + 2;
        if (st.ops) {
          for (const op of st.ops) {
            if (op.expr === null) continue;
            let v = evalExpr(op.expr, ctx);
            if (op.rel) v = sdiff(v, ea + 2) & 0xffff;
            emitWord(ea, v);
            ea += 2;
          }
        }
        break;
      }
    }
  }

  // merge touched bytes into regions
  marks.sort((a, b) => a.start - b.start);
  const regions: { start: number; end: number }[] = [];
  for (const m of marks) {
    const last = regions[regions.length - 1];
    if (last && m.start <= last.end) last.end = Math.max(last.end, m.end);
    else regions.push({ ...m });
  }

  return { image, regions, symbols, lineMap, entry: entry < 0 ? 0o001000 : entry, errors };
}

/**
 * Above 0177 the machine's character set is IBM code page 437 — the
 * pseudographics every micro of the era carried in its character ROM.
 * Box-drawing characters written literally in the source assemble to
 * those codes, so a picture in a .ASCII string stays a picture.
 */
const CP437_HIGH = new Map<string, number>(
  [
    '░▒▓│┤╡╢╖╕╣║╗╝╜╛┐', // 0260..0277
    '└┴┬├─┼╞╟╚╔╩╦╠═╬╧', // 0300..0317
    '╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀', // 0320..0337
  ]
    .join('')
    .split('')
    .map((ch, i) => [ch, 0o260 + i] as const),
);

function parseStringPayload(s: string, err: (m: string) => void): number[] {
  if (s.length < 2) {
    err('.ASCII needs a /delimited/ string');
    return [];
  }
  const delim = s[0];
  const close = s.indexOf(delim, 1);
  if (close < 0) {
    err('unterminated string');
    return [];
  }
  const bytes: number[] = [];
  for (const ch of s.slice(1, close)) bytes.push(CP437_HIGH.get(ch) ?? ch.charCodeAt(0) & 0xff);
  return bytes;
}
