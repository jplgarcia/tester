import { createPublicClient, createWalletClient, http, toHex } from 'viem';
import { foundry } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { walletActionsL1, publicActionsL1, getInputsAdded } from '@cartesi/viem';

const PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const RPC_URL = 'http://127.0.0.1:6751/anvil';
const APP = '0x618f4c02eeaca01fb7c18ff8874c77fdca7bda9a';

const account = privateKeyToAccount(PRIVATE_KEY);
const publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL) }).extend(publicActionsL1());
const walletClient = createWalletClient({ chain: foundry, account, transport: http(RPC_URL) }).extend(walletActionsL1());

const payload = toHex(JSON.stringify({ cmd: 'test' }));
const hash = await walletClient.addInput({ application: APP, payload });
console.log('hash:', hash);
const receipt = await publicClient.waitForTransactionReceipt({ hash });
console.log('receipt.logs count:', receipt.logs.length);
const inputs = getInputsAdded(receipt);
console.log('getInputsAdded type:', typeof inputs);
console.log('getInputsAdded is array:', Array.isArray(inputs));
console.log('getInputsAdded result:', JSON.stringify(inputs, (k, v) => typeof v === 'bigint' ? v.toString() : v, 2));

// Also check walletClient.addInput return type directly
const hash2 = await walletClient.addInput({ application: APP, payload });
const receipt2 = await publicClient.waitForTransactionReceipt({ hash: hash2 });
const raw = getInputsAdded(receipt2);
if (raw && raw[0]) {
  console.log('keys of first element:', Object.keys(raw[0]));
  console.log('inputIndex:', raw[0].inputIndex, typeof raw[0].inputIndex);
}
