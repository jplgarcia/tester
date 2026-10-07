# Cartesi Test DApp

A C++ Cartesi v2 dapp for exercising all rollup primitives: every deposit type, every withdrawal type (via vouchers), delegate-call vouchers, configurable notice/report generation, exception registration, mixed outputs per advance, and an ERC721 voucher-mint flow. Integration tests cover JSON-RPC pagination, ERC-20 `execLayerData` deposits (Rollups v2 `InputEncoding` packed payload), large vouchers, and multi-voucher L1 ordering.

The dapp talks to the machine through **libcmt** (the C library shipped in machine-guest-tools), not through `rollup-http-server`. Outputs are encoded straight into the 2 MiB CMIO transmit buffer, so there is no HTTP/JSON body limit in the way and very large requests cannot kill the dapp with `SIGPIPE`; an output that does not fit the buffer makes the emit call return `-ENOBUFS` (`-105`) and the dapp rejects the input. The machine entrypoint is the dapp binary itself (`/opt/cartesi/dapp/dapp`): if it exits, the machine halts.

---

## Prerequisites

| Tool | Install |
|---|---|
| cartesi CLI | `npm i -g @cartesi/cli` |
| Foundry | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Node.js ≥ 18 | [nodejs.org](https://nodejs.org) |
| Docker | [docker.com](https://docker.com) |

---

## Stack

This repo targets Cartesi Rollups node `v2.0.0-alpha.13` with `rollups-contracts v3.0.0-alpha.10`:

| Component | Version | Pin |
|---|---|---|
| rollups-node | `v2.0.0-alpha.13` | commit `36155487d8bcb1daca5d683b8fa4ec65feba3ab7` |
| rollups-contracts | `v3.0.0-alpha.10` | addresses below |
| machine-guest-tools | `v0.18.0` | `machine-guest-tools_riscv64.deb` sha256 `204d4260defd68e11b957ae1f1b511b6c2c74345c918748be06f592733b72dcd` |
| machine-emulator | `0.21.0` | the emulator used by node alpha.13; the snapshot must be built with it |
| kernel | `linux-6.5.13-ctsi-2-v0.21.0.bin` | sha256 `5c900060da2db2bfa84cd39cd9cd722988c83c42225f3cac55f2d3157e48f32f` (node tag `test/dependencies.sha256`) |

A snapshot built with another emulator version (for example the one pinned by `cartesi build` from CLI `2.0.0-alpha.35`, emulator 0.20.0) has a different template hash and is not loadable by node alpha.13.

## Addresses

rollups-contracts `v3.0.0-alpha.10` is deployed deterministically: the addresses are the same on the local devnet, Sepolia, Base Sepolia and OP Sepolia, so one snapshot serves every network. The portal addresses are compiled into `dapp.cpp` (deposits are recognised by `msg_sender`); a stack with other portal addresses needs a rebuild.

| Contract | Address |
|---|---|
| InputBox | `0xEbE9f4Dfc04ae10bBeE663859c3dc5A23f94eA3C` |
| EtherPortal | `0x035b11Be55656c6cfC822D1CaE568C1Af2e497b0` |
| ERC20Portal | `0x3332DE61a8BB9aC84893b2f552Fe81C9a6dC5419` |
| ERC721Portal | `0x397c352d18DFf47CC8a6143403142cf7afd5Ff7E` |
| ERC1155SinglePortal | `0x585F56351A66f131E176a345662215C772f80451` |
| ERC1155BatchPortal | `0xee33550a22e3Cf6Cc265524dC9bcfD99D2307EBe` |

Run `cartesi address-book` after `cartesi run` starts and copy any changed values into `tests/.env`. Test token contracts can be provided by the devnet or deployed via `forge script Deploy`; their addresses vary per run.

The default Anvil test account used by the tests:

```
address:     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**This is the account with funds.** Use this private key for `forge script Deploy`.

---

## Running

### 1 — Build and start the devnet

`cartesi run` in v2 proxies all services through a single port (default `6751`):

| Endpoint | URL |
|---|---|
| Anvil RPC | `http://127.0.0.1:6751/anvil` |
| Node JSON-RPC | `http://127.0.0.1:6751/rpc` |
| Inspect REST | `http://127.0.0.1:6751/inspect/<dapp-name>` |

For suites **00–07** only, the default epoch length is fine:

```bash
cartesi build
cartesi run
```

Suite **08** (L1 proofs + voucher execution) and the **last test block in 09** (`multi_erc20_withdraw` on L1) need a **short epoch** and matching proofs. For **full `npm test`**, use a short `--epoch-length` and set **`EPOCH_LENGTH`** in `.env` to the same value:

```bash
cartesi run --epoch-length 5
```

The app contract address is printed on startup, e.g.:

```
Cartesi application: 0x75135d8ADb7180640D7f915066F5C710B7D9b8F0
```

### 2 — Deploy test token contracts

First, get the app address from `cartesi run` output and set environment variables:

```bash
# Set the app address (printed by cartesi run)
export CARTESI_APP_ADDRESS=0x<from cartesi run output>

# Set the Anvil test account private key (the default Anvil account)
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**Wait 10+ seconds** for Cartesi to fully initialize Anvil account balances, then deploy:

```bash
# Give Anvil time to initialize (usually ~10 seconds)
sleep 10

cd contracts
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:6751/anvil \
  --broadcast
```

Note the contract addresses printed at the end:

```
=== Deployed ===
TestERC20:              0x...
TestERC721:             0x...
TestERC1155:            0x...
MintableERC721:         0x...
DelegateVoucherLogic:   0x...
```

`Deploy.s.sol` grants the Cartesi app `MINTER_ROLE` on `MintableERC721` so `mint_erc721` vouchers can mint at L1 execution time.

### 3 — Configure the test suite

```bash
cd tests
cp .env.example .env
```

Update `.env` with the addresses from above (see **`.env.example`** for the full list). The key variables are:

| Variable | Description | Source |
|---|---|---|
| `CARTESI_APP_ADDRESS` | App contract from `cartesi run` output | From `cartesi run` |
| `TEST_ERC20_ADDRESS` | TestERC20 | From `forge script Deploy` |
| `TEST_ERC721_ADDRESS` | TestERC721 | From `forge script Deploy` |
| `TEST_ERC1155_ADDRESS` | TestERC1155 | From `forge script Deploy` |
| `MINTABLE_ERC721_ADDRESS` | MintableERC721 | From `forge script Deploy` |
| `DELEGATE_VOUCHER_LOGIC_ADDRESS` | DelegateCall voucher helper | From `forge script Deploy` |
| `RPC_URL` | Anvil RPC | Default: `http://127.0.0.1:6751/anvil` |
| `NODE_RPC_URL` | Cartesi node JSON-RPC | Default: `http://127.0.0.1:6751/rpc` |
| `INSPECT_URL` | Inspect REST — **must include your dapp name**, e.g. `…/inspect/tester` | Default: `http://127.0.0.1:6751/inspect/tester` |
| `PRIVATE_KEY` / `OTHER_PRIVATE_KEY` | Anvil accounts — second key used for targeted delegate-voucher negative tests | See `.env.example` |
| `EPOCH_LENGTH` | Must match `cartesi run --epoch-length` | Default in example: `5`; align with your CLI |

### 4 — Install dependencies and run

```bash
# from the tests/ directory
npm install
npm test
```

To run a single suite:

```bash
npx jest --runInBand tests/01-deposits.test.js
```

---

## Test suites

| File | Description |
|---|---|
| `00-preflight` | Node reachability, Anvil RPC, all contracts deployed |
| `01-deposits` | All 5 portal deposit types — verifies ACCEPTED + notice |
| `02-setup` | `set_mint_contract` — registers MintableERC721 address |
| `03-notices` | Notice size limits: 1 KB, 1 MB, 3×100 KB, 1.25 MB, 2 MB+1 (rejected). |
| `04-reports` | Inspect/report size limits: same cases, silently dropped above 2 MB |
| `05-withdrawals` | All 5 withdrawal voucher types + `mint_erc721` + delegate ERC20 vouchers — verifies voucher created on L2 |
| `06-overdrafts` | Withdrawals without matching deposits — advance ACCEPTED, voucher emitted (L1 would revert) |
| `07-errors` | Invalid JSON, unknown cmd, unknown inspect cmd |
| `08-finalization` | **Requires short epoch** (same `--epoch-length` as `EPOCH_LENGTH` in `.env`) — notice proof on L1, voucher execution + balances, delegate vouchers (including targeted executor), overdraft execution reverts |
| `09-rollups-expanded-coverage` | Exceptions, reports during advance, mixed outputs, JSON-RPC listing/filter/count, ERC-20 voucher `valueField` shapes, ERC-20 deposit with `execLayerData`, large vouchers; **last block** runs two ERC-20 vouchers on L1 in order (**needs short epoch**, same as suite 08) |

---

## Dapp API

All advance inputs are **hex-encoded JSON** (the raw bytes of the UTF-8 JSON string, 0x-prefixed, sent via InputBox).  
All inspect inputs follow the same encoding.

The `test.sh` script handles the encoding automatically; the examples below show the JSON before encoding.

### Advance inputs

#### `set_mint_contract`
Register the `MintableERC721` contract address. Must be called before `mint_erc721`.
```json
{"cmd":"set_mint_contract","address":"0x<MintableERC721>"}
```
Emits a notice confirming the address.

---

#### `generate_notices`
Generate N notices of a given byte size (payload pattern `i & 0xff`). Payloads up to **2,097,056 bytes** fit the 2 MiB output buffer once ABI-encoded; larger sizes cause the advance to be **rejected**.
```json
{"cmd":"generate_notices","size":1024,"count":3}
```

---

#### `force_exception`
Raises an **exception** for the current input (libcmt `cmt_rollup_emit_exception`, payload = `message`). The input finishes with status **`EXCEPTION`** (not `ACCEPTED`) and the application becomes `GUEST_EXCEPTION` (terminal), so use a throwaway app.
```json
{"cmd":"force_exception","message":"optional reason"}
```

---

#### `advance_reports`
Emit reports during an advance (same machine cycle), for testing report linkage to the active input.
```json
{"cmd":"advance_reports","size":1024,"count":2}
```

---

#### `mixed_outputs`
Emit a notice, a report, and a voucher in one advance (optional `noticeText`, `reportText`).
```json
{"cmd":"mixed_outputs","token":"0x...","receiver":"0x...","amount":"0x...","noticeText":"hello","reportText":"log"}
```

---

#### `multi_erc20_withdraw`
Emit **two** ERC-20 transfer vouchers in one advance (tests L1 execution order).
```json
{"cmd":"multi_erc20_withdraw","token":"0x...","receiver":"0x...","amountFirst":"0x...","amountSecond":"0x..."}
```

---

#### `large_voucher`
Emit a voucher with a large arbitrary `payload` (tests calldata size limits). May **reject** the advance if the payload exceeds limits.
```json
{"cmd":"large_voucher","destination":"0x...","payloadBytes":204800}
```

---

#### `eth_withdraw`
Emit a voucher calling `EtherPortal.withdrawEther(receiver, amount)`.
```json
{"cmd":"eth_withdraw","receiver":"0x...","amount":"0x<uint256 wei>"}
```

---

#### `erc20_withdraw`
Emit a voucher calling `token.transfer(receiver, amount)`.

Optional **`valueField`** (for encoding experiments): `"omit"` (no `value` field on the voucher) or `"zero_hash"` (`bytes32(0)`).
```json
{"cmd":"erc20_withdraw","token":"0x...","receiver":"0x...","amount":"0x<uint256>"}
```

---

#### `delegate_erc20_transfer` / `delegate_erc20_transfer_targeted`
Emit a **DelegateCallVoucher** that delegate-calls `DelegateVoucherLogic` to perform `transfer` on the ERC-20 token. The **targeted** variant includes `allowedExecutor`; only that address may execute the voucher on L1.

```json
{"cmd":"delegate_erc20_transfer","logic":"0x...","token":"0x...","receiver":"0x...","amount":"0x..."}
```
```json
{"cmd":"delegate_erc20_transfer_targeted","logic":"0x...","token":"0x...","receiver":"0x...","amount":"0x...","allowedExecutor":"0x..."}
```

---

#### `erc721_withdraw`
Emit a voucher calling `token.safeTransferFrom(appAddress, receiver, tokenId)`.
```json
{"cmd":"erc721_withdraw","token":"0x...","receiver":"0x...","tokenId":"0x<uint256>"}
```

---

#### `erc1155_withdraw_single`
Emit a voucher calling `token.safeTransferFrom(appAddress, receiver, id, amount, "")`.
```json
{"cmd":"erc1155_withdraw_single","token":"0x...","receiver":"0x...","id":"0x1","amount":"0x<uint256>"}
```

---

#### `erc1155_withdraw_batch`
Emit a voucher calling `token.safeBatchTransferFrom(appAddress, receiver, ids, amounts, "")`.
```json
{
  "cmd":"erc1155_withdraw_batch",
  "token":"0x...",
  "receiver":"0x...",
  "ids":["0x1","0x2"],
  "amounts":["0x0a","0x14"]
}
```

---

#### `mint_erc721`
Emit a voucher calling `MintableERC721.mint(receiver, tokenId)`. Requires `set_mint_contract` to have been called first.
```json
{"cmd":"mint_erc721","receiver":"0x...","tokenId":"0x<uint256>"}
```

---

### Inspect inputs

#### `generate_reports`
Generate N reports of a given byte size (same 2 MB limit applies; failures do **not** reject the inspect).
```json
{"cmd":"generate_reports","size":1024,"count":2}
```

#### `echo`
Return the raw payload as a single report — useful for verifying encoding round-trips.
```json
{"cmd":"echo"}
```

---

## Deposits

Deposits are triggered on-chain via the portal contracts. The dapp detects them automatically by checking `msg_sender` against known portal addresses. Each deposit type emits an acknowledgement notice.

| Deposit | Notice payload (decoded) |
|---|---|
| ETH | `ETH OK` |
| ERC20 | `ERC20 OK`, or `ERC20 OK exec=0x…` when `execLayerData` is non-empty (hex of raw exec bytes) |
| ERC721 | `ERC721 OK` |
| ERC1155 single | `1155S OK` |
| ERC1155 batch | `1155B OK` |

### ERC-20 payload encoding (Rollups v2)

On-chain, [`InputEncoding.encodeERC20Deposit`](https://github.com/cartesi/rollups-contracts/blob/v2.0.1/src/common/InputEncoding.sol) uses **`abi.encodePacked`**: `token` (20 B) + `sender` (20 B) + `value` (32 B) + **`execLayerData`** (raw bytes). The dapp decodes **`execLayerData`** from byte offset **72** onward — not standard `abi.encode` with a dynamic offset.

### Note on withdrawals and balance tracking

This dapp is a **test tool** — it does not track balances. Every withdrawal command emits a voucher unconditionally. If the application contract does not actually hold the asset on-chain, the voucher will revert when executed on L1. This is the expected, correct Cartesi model: balance enforcement happens at L1 execution time, not at dapp logic time.

The test suite verifies:
- Valid advances are accepted and vouchers are correctly formed (suite 05)
- Attempting a withdrawal without a prior deposit still emits a voucher (suite 06)
- After epoch finalization, vouchers can be executed on L1 and L1 balances change correctly (suite 08)
- Notices can be validated against the on-chain Merkle root (suite 08)

---

## Troubleshooting

### Large advance notices

With `rollup-http-server` (versions of this dapp before libcmt), a notice above ~2.6 MB made the 6 MB hex JSON body exceed the server's 5 MiB limit; the server answered `400` before reading the body, the dapp died of `SIGPIPE` and the input ended as `EXCEPTION` (terminal app), see [jplgarcia/tester#2](https://github.com/jplgarcia/tester/issues/2). The libcmt build has no such path: any size that does not fit the 2 MiB buffer is a clean `REJECTED`.

### `forge script` fails with "environment variable not found"

**Error:**
```
vm.envAddress: environment variable "CARTESI_APP_ADDRESS" not found
vm.envUint: environment variable "PRIVATE_KEY" not found
```

**Solution:** Set both environment variables before running forge script:

```bash
export CARTESI_APP_ADDRESS=0x<address from cartesi run>
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol --rpc-url http://localhost:6751/anvil --broadcast
```

### `forge script` fails with "Insufficient funds for gas"

**Error:**
```
error code -32003: Insufficient funds for gas * price + value
```

**Cause:** Cartesi's Anvil takes ~10 seconds to initialize account balances. If you run `forge script Deploy` immediately after starting `cartesi run`, the account will have no funds yet.

**Solution:** Wait before deploying:

```bash
# After running "cartesi run", wait at least 10 seconds
sleep 10

# Then deploy
export CARTESI_APP_ADDRESS=0x...
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cd contracts
forge script script/Deploy.s.sol --rpc-url http://localhost:6751/anvil --broadcast
```

**Alternative:** Verify the account is funded before deploying:

```bash
# Check if account has funds (should be > 0x0)
curl -s http://localhost:6751/anvil -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x260c013192813f80c7ded483454383d45cdbd3b0","latest"],"id":1}'

# If result is "0x0", wait a few more seconds and try again
```

### Output size limits

| Output | Encoded as | Max payload |
|---|---|---|
| Notice | `Notice(bytes)`: 4 + 32 + 32 + payload padded to 32 | 2,097,056 bytes |
| Voucher calldata | `Voucher(address,uint256,bytes)`: 4 + 4*32 + payload padded to 32 | 2,096,992 bytes |
| Report | raw bytes | 2,097,152 bytes |

The limit is on the **encoded** output: the whole output must fit the 2,097,152-byte CMIO transmit buffer. A notice/voucher adds its ABI header and 32-byte padding, so the largest notice payload is **2,097,056** bytes (`68 + 32*ceil(n/32) <= 2097152`); a payload of exactly 2 MiB is rejected. Reports are written raw (no header), so a 2,097,152-byte report fits.

Exceeding the limit makes libcmt return `-ENOBUFS` (`-105`), which this dapp propagates as a rejected advance input for notices/reports, and as a silently truncated run (no more reports) for inspect.
