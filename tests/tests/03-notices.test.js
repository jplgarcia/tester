/**
 * Notice size tests — verifies the 2 MB per-notice limit.
 * Uses the `generate_notices` advance command: { cmd, size, count }
 * where size and count are plain integers (not hex).
 */

import {
  sendAdvance, pollInput,
  noticeCount, noticeBytes,
} from '../helpers.js';

const KB = 1024;
const MB = 1024 * KB;
const LIMIT = 2 * MB; // 2,097,152 bytes — max notice size
const LARGE_STABLE = 1280 * KB; // 1,310,720 bytes — large but stable on advance path

describe('Notice size limits', () => {
  test('1 notice of 1 KB — accepted', async () => {
    const idx   = await sendAdvance({ cmd: 'generate_notices', size: KB, count: 1 });
    const input = await pollInput(idx, 120_000);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeBytes(input, 0)).toBe(KB);
  });

  test('1 notice of 1 MB — accepted', async () => {
    const idx   = await sendAdvance({ cmd: 'generate_notices', size: MB, count: 1 });
    const input = await pollInput(idx, 120_000);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeBytes(input, 0)).toBe(MB);
  });

  test('3 notices of 100 KB each — accepted, count=3', async () => {
    const idx   = await sendAdvance({ cmd: 'generate_notices', size: 100 * KB, count: 3 });
    const input = await pollInput(idx, 120_000);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(3);
  });

  test('1 notice of 1.25 MB — accepted', async () => {
    const idx   = await sendAdvance({ cmd: 'generate_notices', size: LARGE_STABLE, count: 1 });
    const input = await pollInput(idx, 120_000);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeBytes(input, 0)).toBe(LARGE_STABLE);
  });

  test('1 notice of 2 MB + 1 byte — advance REJECTED', async () => {
    const idx   = await sendAdvance({ cmd: 'generate_notices', size: LIMIT + 1, count: 1 });
    const input = await pollInput(idx, 120_000);
    expect(input.status).toBe('REJECTED');
    expect(noticeCount(input)).toBe(0);
  });
});
