/**
 * Overdraft tests — withdrawals far exceeding deposited amounts.
 *
 * The dapp has NO balance tracking: it unconditionally emits vouchers for any
 * withdraw command. The advance is always ACCEPTED and the voucher is created;
 * execution would revert on L1 (e.g., insufficient balance) but that is out of
 * scope for dapp-level testing.
 */

import { parseEther } from 'viem';

import {
  ADDR, deployer,
  sendAdvance, pollInput,
  voucherCount,
  uint256hex,
} from '../helpers.js';

describe('Overdrafts (advance ACCEPTED, L1 execution would revert)', () => {
  test('eth_withdraw 1000 ETH (never deposited that much) — ACCEPTED, voucher created', async () => {
    const idx = await sendAdvance({
      cmd:      'eth_withdraw',
      receiver: deployer,
      amount:   uint256hex(parseEther('1000')),
    });
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(voucherCount(input)).toBe(1);
  });

  test('erc20_withdraw 10^30 tokens (exceeds all deposits) — ACCEPTED, voucher created', async () => {
    const huge = 10n ** 30n;
    const idx  = await sendAdvance({
      cmd:      'erc20_withdraw',
      token:    ADDR.TEST_ERC20(),
      receiver: deployer,
      amount:   uint256hex(huge),
    });
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(voucherCount(input)).toBe(1);
  });

  test('erc721_withdraw tokenId=999 (never deposited) — ACCEPTED, voucher created', async () => {
    const idx = await sendAdvance({
      cmd:      'erc721_withdraw',
      token:    ADDR.TEST_ERC721(),
      receiver: deployer,
      tokenId:  uint256hex(999n),
    });
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(voucherCount(input)).toBe(1);
  });

  test('erc1155_withdraw_single id=1 amount=100000 (far exceeds deposit) — ACCEPTED, voucher created', async () => {
    const idx = await sendAdvance({
      cmd:      'erc1155_withdraw_single',
      token:    ADDR.TEST_ERC1155(),
      receiver: deployer,
      id:       uint256hex(1n),
      amount:   uint256hex(100_000n),
    });
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(voucherCount(input)).toBe(1);
  });
});
