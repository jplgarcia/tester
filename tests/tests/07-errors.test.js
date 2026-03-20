/**
 * Error / rejection tests — ensures the dapp correctly rejects bad inputs
 * and handles unknown inspect commands gracefully.
 */

import {
  sendAdvance, sendRawInput, pollInput,
  noticeCount, voucherCount,
  sendInspect, inspectReportCount,
} from '../helpers.js';

describe('Error handling', () => {
  test('invalid JSON advance payload — REJECTED', async () => {
    const idx   = await sendRawInput('this is { not valid json !!');
    const input = await pollInput(idx);
    expect(input.status).toBe('REJECTED');
    expect(noticeCount(input)).toBe(0);
    expect(voucherCount(input)).toBe(0);
  });

  test('unknown advance cmd — REJECTED', async () => {
    const idx   = await sendAdvance({ cmd: 'totally_unknown_command' });
    const input = await pollInput(idx);
    expect(input.status).toBe('REJECTED');
    expect(noticeCount(input)).toBe(0);
    expect(voucherCount(input)).toBe(0);
  });

  test('unknown inspect cmd — ACCEPTED with 1 error report', async () => {
    const resp = await sendInspect({ cmd: 'totally_unknown_inspect_cmd' });
    expect(inspectReportCount(resp)).toBe(1);
    // The report payload is the UTF-8 encoded error string
    const payload = resp.reports[0].payload;
    const text    = Buffer.from(payload.slice(2), 'hex').toString('utf-8');
    expect(text).toMatch(/unknown inspect cmd/i);
  });
});
