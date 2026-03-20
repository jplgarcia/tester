/**
 * Deposit tests — verifies all five portal deposit types.
 * Records input indices in shared state for use by the withdrawal test suite.
 */

import { parseEther } from 'viem';

import state from '../state.js';
import {
  ADDR,
  pollInput,
  noticeCount, noticeText,
  depositEth, depositERC20, depositERC721,
  depositERC1155Single, depositERC1155Batch,
} from '../helpers.js';

describe('Deposits', () => {
  test('ETH deposit — dapp accepts and emits "ETH OK" notice', async () => {
    const idx   = await depositEth(parseEther('0.5'));
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toBe('ETH OK');
    state.idxEthDeposit = idx;
  });

  test('ERC20 deposit — dapp accepts and emits "ERC20 OK" notice', async () => {
    const amount = parseEther('100'); // 100 tokens (18 dec)
    const idx    = await depositERC20(ADDR.TEST_ERC20(), amount);
    const input  = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toBe('ERC20 OK');
    state.idxErc20Deposit = idx;
  });

  test('ERC721 deposit (tokenId=1) — dapp accepts and emits "ERC721 OK" notice', async () => {
    const idx   = await depositERC721(ADDR.TEST_ERC721(), 1n);
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toBe('ERC721 OK');
    state.idxErc721Deposit = idx;
  });

  test('ERC1155 single deposit (id=1, amount=50) — dapp accepts and emits "1155S OK" notice', async () => {
    const idx   = await depositERC1155Single(ADDR.TEST_ERC1155(), 1n, 50n);
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toBe('1155S OK');
    state.idxErc1155SingleDeposit = idx;
  });

  test('ERC1155 batch deposit (ids=[1,2,3], amounts=[10,20,30]) — dapp accepts and emits "1155B OK" notice', async () => {
    const idx   = await depositERC1155Batch(ADDR.TEST_ERC1155(), [1n, 2n, 3n], [10n, 20n, 30n]);
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toBe('1155B OK');
    state.idxErc1155BatchDeposit = idx;
  });
});
