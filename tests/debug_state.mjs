import { createPublicClient, http, parseAbi } from 'viem';
import { foundry } from 'viem/chains';

const RPC_URL = 'http://127.0.0.1:6751/anvil';
const ERC721_ADDR = '0x84eA74d481Ee0A5332c457a4d796187F6Ba67fEB';
const DEPLOYER = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

const ERC721_ABI = parseAbi([
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function balanceOf(address owner) view returns (uint256)',
  'function mint(address to, uint256 tokenId) external',
]);

const client = createPublicClient({ chain: foundry, transport: http(RPC_URL) });

for (let id = 1n; id <= 5n; id++) {
  try {
    const owner = await client.readContract({ address: ERC721_ADDR, abi: ERC721_ABI, functionName: 'ownerOf', args: [id] });
    console.log(`tokenId ${id}: owner = ${owner} (deployer=${owner.toLowerCase() === DEPLOYER.toLowerCase()})`);
  } catch (e) {
    console.log(`tokenId ${id}: error - ${e.message.slice(0, 80)}`);
  }
}

// Also check the node's current input count
const nodeClient = await fetch('http://127.0.0.1:6751/rpc', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_getNodeVersion', params: [], id: 1 }),
});
const ver = await nodeClient.json();
console.log('node version:', ver.result?.data);

// Check status of input 55 (first deposit)
const inputResp = await fetch('http://127.0.0.1:6751/rpc', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_getInput', params: { application: '0x618f4c02eeaca01fb7c18ff8874c77fdca7bda9a', input_index: '0x37' }, id: 2 }),
});
console.log('input 0x37 status:', await inputResp.json());

// Check how many inputs total were sent (getLastInput or similar)
const latestInputResp = await fetch('http://127.0.0.1:6751/rpc', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'cartesi_getInput', params: { application: '0x618f4c02eeaca01fb7c18ff8874c77fdca7bda9a', input_index: '0x0' }, id: 3 }),
});
console.log('input 0 status:', (await latestInputResp.json())?.result?.status);
