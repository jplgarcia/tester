import dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createPublicClient, createWalletClient, http, hexToString, toHex, parseAbi } from 'viem';
import { foundry } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { createCartesiPublicClient, walletActionsL1, publicActionsL1 } from '@cartesi/viem';

const __dirname = dirname(fileURLToPath(import.meta.url));
// Shell-exported vars would otherwise win over tests/.env (dotenv default), which
// breaks runs after changing CARTESI_APP_ADDRESS in the file but not the terminal.
dotenv.config({ path: join(__dirname, '.env'), override: true });

// =============================================================================
// ENV
// =============================================================================
const e = (key) => {
  const v = process.env[key];
  if (!v) throw new Error(`Missing env var: ${key}`);
  return v;
};

const RPC_URL      = process.env.RPC_URL      || 'http://127.0.0.1:6751/anvil';
const NODE_RPC_URL = process.env.NODE_RPC_URL || 'http://127.0.0.1:6751/rpc';
const INSPECT_URL  = process.env.INSPECT_URL  || 'http://127.0.0.1:6751/inspect/tester';

/** Origin (scheme + host + port) for inspect — may differ from JSON-RPC port (see INSPECT_URL). */
function inspectOriginFromEnv() {
  try {
    const u = new URL(INSPECT_URL);
    return `${u.protocol}//${u.host}`;
  } catch {
    return 'http://127.0.0.1:6751';
  }
}
const PRIVATE_KEY  = process.env.PRIVATE_KEY  || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
/** Second Anvil account — for negative tests (e.g. targeted voucher must revert). */
const OTHER_PRIVATE_KEY = process.env.OTHER_PRIVATE_KEY
  || '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

// Contract addresses for Cartesi Rollups node v2.0.0-alpha.12 +
// rollups-contracts v3.0.0-alpha.6. Override from .env when running against a
// different address-book.
const ADDR = {
  APP:                  () => e('CARTESI_APP_ADDRESS'),
  INPUT_BOX:            process.env.INPUT_BOX_ADDRESS    || '0x346B3df038FE9f8380071eC6514D5a83aD143939',
  ETH_PORTAL:           process.env.ETH_PORTAL_ADDRESS   || '0x8b53327575ac999bdfa8003f4b5134DFF9027516',
  ERC20_PORTAL:         process.env.ERC20_PORTAL_ADDRESS || '0x22E57511C30CcE6CDaa742E13CE3b774fDC663b1',
  ERC721_PORTAL:        process.env.ERC721_PORTAL_ADDRESS|| '0xcA3a0a47915C12F020CF70B938aCC8e744414cb8',
  ERC1155_SINGLE_PORTAL:process.env.ERC1155_SINGLE_PORTAL|| '0x13663E193673756a02e84b724B8a3422A9a7aab4',
  ERC1155_BATCH_PORTAL: process.env.ERC1155_BATCH_PORTAL || '0x3649c5E2De91C69a7Bb80D864f0039da5E511096',
  TEST_ERC20:           () => e('TEST_ERC20_ADDRESS'),
  TEST_ERC721:          () => e('TEST_ERC721_ADDRESS'),
  TEST_ERC1155:         () => e('TEST_ERC1155_ADDRESS'),
  MINTABLE_ERC721:      () => e('MINTABLE_ERC721_ADDRESS'),
  DELEGATE_VOUCHER_LOGIC: () => e('DELEGATE_VOUCHER_LOGIC_ADDRESS'),
};

// =============================================================================
// CLIENTS
// =============================================================================
const account = privateKeyToAccount(PRIVATE_KEY);
const accountOther = privateKeyToAccount(OTHER_PRIVATE_KEY);

// L1 public client — getCode, getBlockNumber, waitForTransactionReceipt, validateOutput, etc.
const publicClient = createPublicClient({
  chain: foundry,
  transport: http(RPC_URL),
}).extend(publicActionsL1());

// L1 wallet client — addInput, depositXxx, writeContract (approvals)
const walletClient = createWalletClient({
  chain: foundry,
  account,
  transport: http(RPC_URL),
}).extend(walletActionsL1());

const walletClientOther = createWalletClient({
  chain: foundry,
  account: accountOther,
  transport: http(RPC_URL),
}).extend(walletActionsL1());

// L2 Cartesi node client — waitForInput, listOutputs, listReports, getNodeVersion
const publicClientL2 = createCartesiPublicClient({
  transport: http(NODE_RPC_URL),
});

const deployer = account.address;
/** Address of `OTHER_PRIVATE_KEY` — use as non-targeted executor in tests. */
const otherUser = accountOther.address;

function inputIndexFromReceipt(receipt) {
  const inputBox = ADDR.INPUT_BOX.toLowerCase();
  const log = receipt.logs.find((entry) =>
    entry.address.toLowerCase() === inputBox && entry.topics.length >= 3
  );
  if (!log) {
    throw new Error(`InputAdded log not found in transaction ${receipt.transactionHash}`);
  }
  return BigInt(log.topics[2]);
}

const INPUT_BOX_ABI = parseAbi(['function addInput(address appContract, bytes payload) external returns (bytes32)']);

async function addInput(payload) {
  return walletClient.writeContract({
    address: ADDR.INPUT_BOX,
    abi: INPUT_BOX_ABI,
    functionName: 'addInput',
    args: [ADDR.APP(), payload],
  });
}

// =============================================================================
// ADVANCE INPUT — send JSON as hex-encoded payload
// =============================================================================
/**
 * Send a JSON object as an advance input.
 * @param {object} json
 * @returns {Promise<bigint>} input index
 */
async function sendAdvance(json) {
  const payload = toHex(JSON.stringify(json));
  const hash    = await addInput(payload);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/**
 * Send a raw string (not JSON-serialized) as an advance input.
 * Useful for testing invalid-JSON rejection.
 * @param {string} rawString  — will be UTF-8 encoded to bytes
 * @returns {Promise<bigint>} input index
 */
async function sendRawInput(rawString) {
  const payload = toHex(rawString);
  const hash    = await addInput(payload);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

// =============================================================================
// L2 INPUT POLLING — polls getInput until terminal status, then fetches outputs
// =============================================================================
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Poll the Cartesi node until the input reaches a terminal status,
 * then return { status, notices, reports, vouchers }.
 * @param {bigint|number} index
 * @param {number} timeoutMs
 */
async function pollInput(index, timeoutMs = 90_000) {
  const deadline = Date.now() + timeoutMs;
  const app      = ADDR.APP();
  const bigIdx   = BigInt(index);

  let inputResult;
  while (Date.now() < deadline) {
    try {
      inputResult = await publicClientL2.getInput({ application: app, inputIndex: bigIdx });
    } catch (err) {
      // Node throws ResourceNotFoundRpcError while the input is still being
      // indexed — treat it the same as status 'NONE' and keep polling.
      if (err?.name === 'ResourceNotFoundRpcError' ||
          (err?.cause?.message ?? err?.message ?? '').includes('not found')) {
        await sleep(1000);
        continue;
      }
      throw err;
    }
    const st = inputResult?.status;
    if (st && st !== 'NONE') break;
    await sleep(1000);
  }
  if (!inputResult || inputResult.status === 'NONE') {
    throw new Error(`Input ${index} timed out after ${timeoutMs}ms`);
  }

  if (inputResult.status === 'EXCEPTION') {
    return {
      status:     'EXCEPTION',
      epochIndex: inputResult.epochIndex,
      notices:    [],
      reports:    [],
      vouchers:   [],
    };
  }

  const [outputsResult, reportsResult] = await Promise.all([
    publicClientL2.listOutputs({ application: app, inputIndex: bigIdx }),
    publicClientL2.listReports({ application: app, inputIndex: bigIdx }),
  ]);

  const allOutputs = outputsResult.data || [];
  const notices  = allOutputs.filter(o => o.decodedData?.type === 'Notice');
  const vouchers = allOutputs.filter(o =>
    o.decodedData?.type === 'Voucher' || o.decodedData?.type === 'DelegateCallVoucher'
  );

  return {
    status:     inputResult.status,
    epochIndex: inputResult.epochIndex,
    notices,
    reports:    reportsResult.data || [],
    vouchers,
  };
}

// =============================================================================
// OUTPUT ACCESSORS
// =============================================================================

/** Number of notices emitted by the input. */
const noticeCount  = (input) => input.notices.length;
/** Number of reports emitted by the input. */
const reportCount  = (input) => input.reports.length;
/** Number of vouchers emitted by the input. */
const voucherCount = (input) => input.vouchers.length;

/** Decode the Nth notice payload as a UTF-8 string. */
const noticeText = (input, n = 0) => {
  const payload = input.notices[n]?.decodedData?.payload;
  return payload ? hexToString(payload) : '';
};

/** Return the byte length of the Nth notice's raw binary payload. */
const noticeBytes = (input, n = 0) => {
  const payload = input.notices[n]?.decodedData?.payload;
  return payload ? (payload.length - 2) / 2 : 0;
};

/** Decode the Nth report rawData as a UTF-8 string. */
const reportText = (input, n = 0) => {
  const rawData = input.reports[n]?.rawData;
  return rawData ? hexToString(rawData) : '';
};

/** Return the destination address (lowercase) of the Nth voucher. */
const voucherDest = (input, n = 0) =>
  (input.vouchers[n]?.decodedData?.destination ?? '').toLowerCase();

// =============================================================================
// INSPECT — REST GET endpoint on the Cartesi node
// =============================================================================
/**
 * Send an inspect request with a JSON payload.
 * Returns { status, reports: [{ payload }] }
 * @param {object} json
 */
async function sendInspect(json) {
  // Cartesi v2: POST /inspect/{app_address}  body: {"payload":"0x{hex}"}
  // Inspect is often on a different port than JSON-RPC — derive origin from INSPECT_URL
  // (e.g. http://127.0.0.1:10012/inspect/tester → http://127.0.0.1:10012).
  const hexPayload = '0x' + Buffer.from(JSON.stringify(json)).toString('hex');
  const url = `${inspectOriginFromEnv()}/inspect/${ADDR.APP()}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ payload: hexPayload }),
  });
  if (!res.ok) throw new Error(`Inspect HTTP ${res.status}`);
  return res.json();
}

/** Number of reports in an inspect response. */
const inspectReportCount = (resp) => resp?.reports?.length ?? 0;

/** Byte length of the Nth report payload in an inspect response (REST format: .payload). */
const inspectReportBytes = (resp, n = 0) => {
  const payload = resp?.reports?.[n]?.payload;
  return payload ? (payload.length - 2) / 2 : 0;
};

// =============================================================================
// DEPOSIT HELPERS
// =============================================================================
const ERC20_ABI   = parseAbi(['function approve(address spender, uint256 amount) external returns (bool)']);
const ERC721_ABI  = parseAbi(['function approve(address to, uint256 tokenId) external']);
const ERC1155_ABI = parseAbi(['function setApprovalForAll(address operator, bool approved) external']);
const ETHER_PORTAL_ABI = parseAbi(['function depositEther(address appContract, bytes execLayerData) external payable']);
const ERC20_PORTAL_ABI = parseAbi(['function depositERC20Tokens(address token, address appContract, uint256 value, bytes execLayerData) external']);
const ERC721_PORTAL_ABI = parseAbi(['function depositERC721Token(address token, address appContract, uint256 tokenId, bytes baseLayerData, bytes execLayerData) external']);
const ERC1155_SINGLE_PORTAL_ABI = parseAbi(['function depositSingleERC1155Token(address token, address appContract, uint256 id, uint256 amount, bytes baseLayerData, bytes execLayerData) external']);
const ERC1155_BATCH_PORTAL_ABI = parseAbi(['function depositBatchERC1155Token(address token, address appContract, uint256[] ids, uint256[] amounts, bytes baseLayerData, bytes execLayerData) external']);

async function depositEth(weiAmount) {
  const hash = await walletClient.writeContract({
    address:      ADDR.ETH_PORTAL,
    abi:          ETHER_PORTAL_ABI,
    functionName: 'depositEther',
    args:         [ADDR.APP(), '0x'],
    value:        weiAmount,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/** Ether deposit with non-empty `execLayerData` (ABI-encoded bytes on the portal). */
async function depositEthWithExecLayer(weiAmount, execLayerDataHex) {
  const hash = await walletClient.writeContract({
    address:      ADDR.ETH_PORTAL,
    abi:          ETHER_PORTAL_ABI,
    functionName: 'depositEther',
    args:         [ADDR.APP(), execLayerDataHex],
    value:        weiAmount,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

async function depositERC20(tokenAddr, amount) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC20_ABI,
    functionName: 'approve',
    args:         [ADDR.ERC20_PORTAL, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC20_PORTAL,
    abi:          ERC20_PORTAL_ABI,
    functionName: 'depositERC20Tokens',
    args:         [tokenAddr, ADDR.APP(), amount, '0x'],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/** ERC-20 deposit with non-empty `execLayerData` (ABI-encoded bytes on the portal). */
async function depositERC20WithExecLayer(tokenAddr, amount, execLayerDataHex) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC20_ABI,
    functionName: 'approve',
    args:         [ADDR.ERC20_PORTAL, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC20_PORTAL,
    abi:          ERC20_PORTAL_ABI,
    functionName: 'depositERC20Tokens',
    args:         [tokenAddr, ADDR.APP(), amount, execLayerDataHex],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

async function depositERC721(tokenAddr, tokenId) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC721_ABI,
    functionName: 'approve',
    args:         [ADDR.ERC721_PORTAL, tokenId],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC721_PORTAL,
    abi:          ERC721_PORTAL_ABI,
    functionName: 'depositERC721Token',
    args:         [tokenAddr, ADDR.APP(), tokenId, '0x', '0x'],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/** ERC-721 deposit with explicit `baseLayerData` and `execLayerData`. */
async function depositERC721WithLayerData(tokenAddr, tokenId, baseLayerDataHex, execLayerDataHex) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC721_ABI,
    functionName: 'approve',
    args:         [ADDR.ERC721_PORTAL, tokenId],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC721_PORTAL,
    abi:          ERC721_PORTAL_ABI,
    functionName: 'depositERC721Token',
    args:         [tokenAddr, ADDR.APP(), tokenId, baseLayerDataHex, execLayerDataHex],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

async function depositERC1155Single(tokenAddr, id, amount) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC1155_ABI,
    functionName: 'setApprovalForAll',
    args:         [ADDR.ERC1155_SINGLE_PORTAL, true],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC1155_SINGLE_PORTAL,
    abi:          ERC1155_SINGLE_PORTAL_ABI,
    functionName: 'depositSingleERC1155Token',
    args:         [tokenAddr, ADDR.APP(), id, amount, '0x', '0x'],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/** ERC-1155 single deposit with explicit `baseLayerData` and `execLayerData`. */
async function depositERC1155SingleWithLayerData(tokenAddr, id, amount, baseLayerDataHex, execLayerDataHex) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC1155_ABI,
    functionName: 'setApprovalForAll',
    args:         [ADDR.ERC1155_SINGLE_PORTAL, true],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC1155_SINGLE_PORTAL,
    abi:          ERC1155_SINGLE_PORTAL_ABI,
    functionName: 'depositSingleERC1155Token',
    args:         [tokenAddr, ADDR.APP(), id, amount, baseLayerDataHex, execLayerDataHex],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

async function depositERC1155Batch(tokenAddr, ids, amounts) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC1155_ABI,
    functionName: 'setApprovalForAll',
    args:         [ADDR.ERC1155_BATCH_PORTAL, true],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC1155_BATCH_PORTAL,
    abi:          ERC1155_BATCH_PORTAL_ABI,
    functionName: 'depositBatchERC1155Token',
    args:         [tokenAddr, ADDR.APP(), ids, amounts, '0x', '0x'],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

/** ERC-1155 batch deposit with explicit `baseLayerData` and `execLayerData`. */
async function depositERC1155BatchWithLayerData(tokenAddr, ids, amounts, baseLayerDataHex, execLayerDataHex) {
  const approveHash = await walletClient.writeContract({
    address:      tokenAddr,
    abi:          ERC1155_ABI,
    functionName: 'setApprovalForAll',
    args:         [ADDR.ERC1155_BATCH_PORTAL, true],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const hash = await walletClient.writeContract({
    address:      ADDR.ERC1155_BATCH_PORTAL,
    abi:          ERC1155_BATCH_PORTAL_ABI,
    functionName: 'depositBatchERC1155Token',
    args:         [tokenAddr, ADDR.APP(), ids, amounts, baseLayerDataHex, execLayerDataHex],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return inputIndexFromReceipt(receipt);
}

// =============================================================================
// ANVIL UTILITIES
// =============================================================================

/**
 * Mine `n` blocks on the local Anvil devnet (advances epoch progression).
 * @param {number} n
 */
async function mineBlocks(n) {
  // anvil_mine(hexCount, hexIntervalSeconds)
  await publicClient.request({ method: 'anvil_mine', params: [`0x${n.toString(16)}`, '0x1'] });
}

// =============================================================================
// EPOCH CLAIM + OUTPUT PROOFS (L1 validateOutput / executeOutput)
// =============================================================================

/**
 * Poll until the node's epoch reaches CLAIM_ACCEPTED (hard acceptance for claims).
 * Mines a few L1 blocks periodically so the node can advance even with long
 * epoch lengths or slow polling.
 * @param {bigint} epochIndex
 * @param {number} timeoutMs
 */
async function waitForEpochClaimAccepted(epochIndex, timeoutMs = 600_000) {
  const app      = ADDR.APP();
  const deadline = Date.now() + timeoutMs;
  const ei       = BigInt(epochIndex);
  let ticks      = 0;
  while (Date.now() < deadline) {
    try {
      const epoch = await publicClientL2.getEpoch({ application: app, epochIndex: ei });
      if (epoch?.status === 'CLAIM_ACCEPTED') return epoch;
    } catch {
      // Epoch row may not exist yet on the node; keep mining and polling.
    }
    if (++ticks % 5 === 0) await mineBlocks(2).catch(() => {});
    await sleep(2000);
  }
  throw new Error(`Epoch ${ei} not CLAIM_ACCEPTED after ${timeoutMs}ms`);
}

/**
 * Fetch a single output after CLAIM_ACCEPTED; proofs should already be attached.
 * One retry with extra mining covers occasional node lag.
 * @param {bigint|number|string} outputIndex — global output index
 * @param {number} timeoutMs
 */
async function getOutputWithProof(outputIndex, timeoutMs = 60_000) {
  const app      = ADDR.APP();
  const bigIdx   = BigInt(outputIndex);
  const deadline = Date.now() + timeoutMs;

  async function once() {
    return publicClientL2.getOutput({ application: app, outputIndex: bigIdx });
  }

  let output = await once();
  if (output?.outputHashesSiblings !== null) return output;

  await mineBlocks(2).catch(() => {});
  await sleep(500);
  output = await once();
  if (output?.outputHashesSiblings !== null) return output;

  while (Date.now() < deadline) {
    await mineBlocks(2).catch(() => {});
    await sleep(1000);
    output = await once();
    if (output?.outputHashesSiblings !== null) return output;
  }
  throw new Error(`Output ${outputIndex} missing Merkle siblings after CLAIM_ACCEPTED (${timeoutMs}ms)`);
}

// =============================================================================
// VOUCHER EXECUTION
// =============================================================================

/**
 * Execute a voucher on L1 (calls the application's executeOutput).
 * Returns the transaction receipt.
 * @param {object} output  — full Output object with proof
 * @param {{ walletClient?: import('viem').WalletClient }} [opts]  — optional signer (default: deployer)
 */
async function executeVoucher(output, opts = {}) {
  const wc = opts.walletClient ?? walletClient;
  const hash = await wc.executeOutput({ application: ADDR.APP(), output });
  return publicClient.waitForTransactionReceipt({ hash });
}

/**
 * Validate a notice on L1 (read-only, no gas cost).
 * Returns true if the Merkle proof is valid.
 * @param {object} output  — full Output object for a Notice, with proof
 */
async function validateNotice(output) {
  return publicClient.validateOutput({ application: ADDR.APP(), output });
}

// =============================================================================
// MISC
// =============================================================================

/** Encode a JS bigint/number as a 0x-prefixed 32-byte hex string for JSON args. */
const uint256hex = (v) => toHex(BigInt(v), { size: 32 });

export {
  ADDR,
  deployer,
  otherUser,
  publicClient,
  publicClientL2,
  walletClient,
  walletClientOther,
  sendAdvance,
  sendRawInput,
  pollInput,
  mineBlocks,
  waitForEpochClaimAccepted,
  getOutputWithProof,
  executeVoucher,
  validateNotice,
  noticeCount, reportCount, voucherCount,
  noticeText, noticeBytes,
  reportText,
  voucherDest,
  sendInspect,
  inspectReportCount, inspectReportBytes,
  depositEth, depositEthWithExecLayer,
  depositERC20, depositERC20WithExecLayer, depositERC721, depositERC721WithLayerData,
  depositERC1155Single, depositERC1155SingleWithLayerData,
  depositERC1155Batch, depositERC1155BatchWithLayerData,
  uint256hex,
  sleep,
};
