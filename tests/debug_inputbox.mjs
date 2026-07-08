// Find the right InputBox and check all InputAdded events regardless of app
import { createPublicClient, http, parseAbi } from 'viem';
import { foundry } from 'viem/chains';

const ANVIL = 'http://127.0.0.1:6751/anvil';
const client = createPublicClient({ chain: foundry, transport: http(ANVIL) });

// Check all events from all known InputBox addresses
const INPUT_BOXES = [
  '0x346B3df038FE9f8380071eC6514D5a83aD143939',
];

const InputAddedABI = parseAbi(['event InputAdded(address indexed dapp, uint256 indexed inputIndex, address sender, bytes input)']);

const blockNumber = await client.getBlockNumber();
console.log('Block number:', blockNumber.toString());

for (const addr of INPUT_BOXES) {
  const code = await client.getCode({ address: addr });
  console.log(`\nInputBox ${addr}: code length = ${code?.length ?? 0}`);
  if (code && code.length > 2) {
    const logs = await client.getLogs({
      address: addr,
      event: InputAddedABI[0],
      fromBlock: 0n,
    });
    console.log(`  Total InputAdded events: ${logs.length}`);
    logs.slice(-5).forEach(l => {
      console.log(`  dapp=${l.args.dapp} idx=${l.args.inputIndex} block=${l.blockNumber}`);
    });
  }
}

// Also check address book from the node
const abResp = await fetch('http://127.0.0.1:6751/rpc', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_getNodeVersion', params: [], id: 1 }),
});
const ab = await abResp.json();
console.log('\nNode version:', ab?.result?.data);
