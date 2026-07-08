// Check exact current state
const APP = process.env.CARTESI_APP_ADDRESS || '0xc192bb886f77807f0101ecc7566e653ac03b0b19';
const ANVIL = 'http://127.0.0.1:6751/anvil';
const RPC = 'http://127.0.0.1:6751/rpc';

// Check block number
const blkResp = await fetch(ANVIL, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'eth_blockNumber', params: [], id: 1 }),
});
const blk = await blkResp.json();
console.log('Current block:', parseInt(blk.result, 16));

// Check InputBox InputAdded event count for this app
const { createPublicClient, http, parseAbi } = await import('viem');
const { foundry } = await import('viem/chains');
const client = createPublicClient({ chain: foundry, transport: http(ANVIL) });

const INPUT_BOX = process.env.INPUT_BOX_ADDRESS || '0x346B3df038FE9f8380071eC6514D5a83aD143939';
const InputBoxABI = parseAbi(['event InputAdded(address indexed dapp, uint256 indexed inputIndex, address sender, bytes input)']);

const logs = await client.getLogs({
  address: INPUT_BOX,
  event: InputBoxABI[0],
  args: { dapp: APP },
  fromBlock: 0n,
});
console.log('Total InputAdded events for this app:', logs.length);
if (logs.length > 0) {
  const last = logs[logs.length - 1];
  console.log('Last inputIndex:', last.args.inputIndex?.toString());
  console.log('Last block:', last.blockNumber?.toString());
}

// Check the direct cartesi_listInputs if it exists
const listResp = await fetch(RPC, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_listInputs', params: { application: APP, length: '0xa', start: '0x0' }, id: 2 }),
});
const list = await listResp.json();
console.log('cartesi_listInputs result:', JSON.stringify(list, null, 2));
