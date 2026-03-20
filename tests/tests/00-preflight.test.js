/**
 * Pre-flight: verify that cartesi node, Anvil, and all contracts are reachable
 * before any test sends a transaction.
 */

import { publicClient, publicClientL2, ADDR } from '../helpers.js';

describe('Pre-flight', () => {
  test('Cartesi node JSON-RPC is reachable', async () => {
    const version = await publicClientL2.getNodeVersion();
    expect(typeof version).toBe('string');
    expect(version.length).toBeGreaterThan(0);
  });

  test('Anvil RPC is reachable', async () => {
    const block = await publicClient.getBlockNumber();
    expect(typeof block).toBe('bigint');
  });

  test('TestERC20 is deployed', async () => {
    const code = await publicClient.getCode({ address: ADDR.TEST_ERC20() });
    expect(code).not.toBe('0x');
  });

  test('TestERC721 is deployed', async () => {
    const code = await publicClient.getCode({ address: ADDR.TEST_ERC721() });
    expect(code).not.toBe('0x');
  });

  test('TestERC1155 is deployed', async () => {
    const code = await publicClient.getCode({ address: ADDR.TEST_ERC1155() });
    expect(code).not.toBe('0x');
  });

  test('MintableERC721 is deployed', async () => {
    const code = await publicClient.getCode({ address: ADDR.MINTABLE_ERC721() });
    expect(code).not.toBe('0x');
  });

  test('Cartesi app contract is deployed', async () => {
    const code = await publicClient.getCode({ address: ADDR.APP() });
    expect(code).not.toBe('0x');
  });
});

