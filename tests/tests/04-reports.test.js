/**
 * Inspect / report size tests — verifies the 2 MB per-report limit via REST.
 * Uses the `generate_reports` inspect command: { cmd, size, count }
 * where size and count are plain integers (not hex).
 * The inspect endpoint always returns "Accepted"; oversized reports are silently dropped.
 */

import {
  sendInspect,
  inspectReportCount, inspectReportBytes,
} from '../helpers.js';

const KB = 1024;
const MB = 1024 * KB;
const LIMIT = 2 * MB; // 2,097,152 bytes — max report size
const LIMIT_UNDER = 1900 * KB; // 1,945,600 bytes — 1.85 MB (just under 2 MB limit)

describe('Report size limits (inspect)', () => {
  test('1 report of 1 KB — count=1, size=1024', async () => {
    const resp = await sendInspect({ cmd: 'generate_reports', size: KB, count: 1 });
    expect(inspectReportCount(resp)).toBe(1);
    expect(inspectReportBytes(resp, 0)).toBe(KB);
  });

  test('1 report of 1 MB — count=1, size=1048576', async () => {
    const resp = await sendInspect({ cmd: 'generate_reports', size: MB, count: 1 });
    expect(inspectReportCount(resp)).toBe(1);
    expect(inspectReportBytes(resp, 0)).toBe(MB);
  });

  test('2 reports of 500 KB each — count=2', async () => {
    const resp = await sendInspect({ cmd: 'generate_reports', size: 500 * KB, count: 2 });
    expect(inspectReportCount(resp)).toBe(2);
  });

  test('1 report of 1.85 MB (under 2 MB limit) — count=1, size=1945600', async () => {
    const resp = await sendInspect({ cmd: 'generate_reports', size: LIMIT_UNDER, count: 1 });
    expect(inspectReportCount(resp)).toBe(1);
    expect(inspectReportBytes(resp, 0)).toBe(LIMIT_UNDER);
  });

  test('1 report of 2 MB + 1 byte — silently dropped, count=0 (inspect still accepted)', async () => {
    const resp = await sendInspect({ cmd: 'generate_reports', size: LIMIT + 1, count: 1 });
    expect(inspectReportCount(resp)).toBe(0);
  });

  test('echo — emits back the raw payload as a report', async () => {
    const resp = await sendInspect({ cmd: 'echo' });
    expect(inspectReportCount(resp)).toBe(1);
  });
});
