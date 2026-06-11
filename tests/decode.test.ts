import { describe, expect, it } from 'vitest';
import { DEFS, RESERVED, decode } from '../src/core/instructions';

describe('decoder vs programmer card', () => {
  it('card entries never overlap', () => {
    for (let w = 0; w < 0x10000; w++) {
      const matches = DEFS.filter((d) => (w & d.mask) === d.pattern);
      if (matches.length > 1) {
        expect.fail(`word ${w.toString(8)} matches ${matches.map((d) => d.name).join(', ')}`);
      }
    }
  });

  it('the switch cascade agrees with pattern/mask on all 65536 words', () => {
    const mismatches: string[] = [];
    for (let w = 0; w < 0x10000; w++) {
      let expected = RESERVED;
      for (const d of DEFS) {
        if ((w & d.mask) === d.pattern) {
          expected = d;
          break;
        }
      }
      const got = decode(w);
      if (got !== expected) {
        mismatches.push(`${w.toString(8).padStart(6, '0')}: card=${expected.name} decode=${got.name}`);
        if (mismatches.length > 10) break;
      }
    }
    expect(mismatches).toEqual([]);
  });
});
