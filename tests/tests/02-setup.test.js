/**
 * Setup — registers the MintableERC721 contract address in the dapp.
 * Must run before any mint_erc721 test.
 */

import {
  ADDR, sendAdvance, pollInput,
  noticeCount, noticeText,
} from '../helpers.js';

describe('Setup', () => {
  test('set_mint_contract — dapp accepts and confirms address in notice', async () => {
    const mintAddr = ADDR.MINTABLE_ERC721();
    const idx   = await sendAdvance({ cmd: 'set_mint_contract', address: mintAddr });
    const input = await pollInput(idx);
    expect(input.status).toBe('ACCEPTED');
    expect(noticeCount(input)).toBe(1);
    expect(noticeText(input, 0)).toMatch(/^mint_contract=/i);
    expect(noticeText(input, 0).toLowerCase()).toContain(mintAddr.toLowerCase());
  });
});
