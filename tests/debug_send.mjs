import { createPublicClient, createWalletClient, http, toHex } from 'viem';
import { foundry } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { walletActionsL1, publicActionsL1, getInputsAdded } from '@cartesi/viem';

const PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const RPC_URL = 'http://127.0.0.1:6751/anvil';
const APP = '0x618f4c02eeaca01fb7c18ff8874c77fdca7bda9a';
const INPUT_BOX = '0x1b51e2992A2755Ba4D6F7094032DF91991a0Cfac';

const account = privateKeyToAccount(PRIVATE_KEY);
const publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL) }).extend(publicActionsL1());
const walletClient = createWalletClient({ chain: foundry, account, transport: http(RPC_URL) }).extend(walletActionsL1());

const payload = toHex(JSON.stringify({ cmd: 'test_fresh' }));
const hash = await walletClient.addInput({ application: APP, payload });
console.log('tx hash:', hash);
const receipt = await publicClient.waitForTransactionReceipt({ hash });
console.log('receipt.status:', receipt.status);
console.log('receipt.to:', receipt.to);
console.log('receipt.logs:', JSON.stringify(receipt.logs, (k,v) => typeof v === 'bigint' ? v.toString() : v, 2));

// Now check if it's in the InputBox
const { createPublicClient: cpc, http: h, parseAbi } = await import('viem');
const client2 = cpc({ chain: foundry, transport: h(RPC_URL) });
const InputAddedABI = parseAbi(['event InputAdded(address indexed dapp, uint256 indexed inputIndex, address sender, bytes input)']);
const logs = await client2.getLogs({ address: INPUT_BOX, event: InputAddedABI[0], fromBlock: 0n });
console.log('\nTotal InputAdded events after sendAdvance:', logs.length);
if (logs.length > 0) {
  const last = logs[logs.length-1];
  console.log('Last log dapp:', last.args.dapp);
  console.log('Last log inputIndex:', last.args.inputIndex?.toString());
}
