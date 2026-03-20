# Cartesi Test DApp

A C++ Cartesi v2 dapp for exercising all rollup primitives: every deposit type, every withdrawal type (via vouchers), configurable notice/report generation, and an ERC721 voucher-mint flow.

---

## Prerequisites

| Tool | Install |
|---|---|
| cartesi CLI | `npm i -g @cartesi/cli` |
| Foundry | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Node.js ≥ 18 | [nodejs.org](https://nodejs.org) |
| Docker | [docker.com](https://docker.com) |

---

## Addresses (injected by `cartesi run`)

These are stable across all cartesi CLI local devnets (`address-book`):

| Contract | Address |
|---|---|
| InputBox | `0x1b51e2992A2755Ba4D6F7094032DF91991a0Cfac` |
| EtherPortal | `0xA632c5c05812c6a6149B7af5C56117d1D2603828` |
| ERC20Portal | `0xACA6586A0Cf05bD831f2501E7B4aea550dA6562D` |
| ERC721Portal | `0x9E8851dadb2b77103928518846c4678d48b5e371` |
| ERC1155SinglePortal | `0x18558398Dd1a8cE20956287a4Da7B76aE7A96662` |
| ERC1155BatchPortal | `0xe246Abb974B307490d9C6932F48EbE79de72338A` |

Test token contracts are deployed via `forge script Deploy` and their addresses vary per run.

The default Anvil test account used by the tests:

```
address:     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

---

## Running

### 1 — Build and start the devnet

`cartesi run` in v2 proxies all services through a single port (default `6751`):

| Endpoint | URL |
|---|---|
| Anvil RPC | `http://127.0.0.1:6751/anvil` |
| Node JSON-RPC | `http://127.0.0.1:6751/rpc` |
| Inspect REST | `http://127.0.0.1:6751/inspect/<dapp-name>` |

For suites 00–07 (no voucher execution), the default epoch length is fine:

```bash
cartesi build
cartesi run
```

For suite 08 (voucher execution + notice validation on L1) you need a short epoch so proofs are available quickly:

```bash
cartesi run --epoch-length 5
```

The app contract address is printed on startup, e.g.:

```
Cartesi application: 0x75135d8ADb7180640D7f915066F5C710B7D9b8F0
```

### 2 — Deploy test token contracts

```bash
cd contracts
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast -vv
```

Note the addresses printed at the end and export them:

```bash
export CARTESI_APP_ADDRESS=0x<from cartesi run output>
export TEST_ERC20_ADDRESS=0x...
export TEST_ERC721_ADDRESS=0x...
export TEST_ERC1155_ADDRESS=0x...
export MINTABLE_ERC721_ADDRESS=0x...
```

### 3 — Configure the test suite

```bash
cd tests
cp .env.example .env
# fill in the five addresses exported above
```

Key variables in `.env`:

| Variable | Description |
|---|---|
| `CARTESI_APP_ADDRESS` | App contract from `cartesi run` |
| `TEST_ERC20_ADDRESS` | Deployed by `forge script Deploy` |
| `TEST_ERC721_ADDRESS` | Deployed by `forge script Deploy` |
| `TEST_ERC1155_ADDRESS` | Deployed by `forge script Deploy` |
| `MINTABLE_ERC721_ADDRESS` | Deployed by `forge script Deploy` |
| `RPC_URL` | Anvil RPC (default `http://127.0.0.1:6751/anvil`) |
| `NODE_RPC_URL` | Cartesi node JSON-RPC (default `http://127.0.0.1:6751/rpc`) |
| `INSPECT_URL` | Cartesi inspect REST (default `http://127.0.0.1:6751/inspect/tester`) |
| `EPOCH_LENGTH` | Must match `--epoch-length` flag (default `5`) — used by suite 08 only |

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
| `03-notices` | Notice size limits: 1 KB, 1 MB, 3×100 KB, exact 2 MB (accepted), 2 MB+1 (rejected) |
| `04-reports` | Inspect/report size limits: same cases, silently dropped above 2 MB |
| `05-withdrawals` | All 5 withdrawal voucher types + `mint_erc721` — verifies voucher created on L2 |
| `06-overdrafts` | Withdrawals without matching deposits — advance ACCEPTED, voucher emitted (L1 would revert) |
| `07-errors` | Invalid JSON, unknown cmd, unknown inspect cmd |
| `08-finalization` | **Requires `--epoch-length 5`** — mines epoch, validates notice proof on L1, executes all 6 vouchers and checks L1 balances |

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
Generate N notices of a given byte size. Sizes up to **2,097,152 bytes (2 MB)** are accepted. Larger sizes cause the advance to be **rejected**.
```json
{"cmd":"generate_notices","size":1024,"count":3}
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
```json
{"cmd":"erc20_withdraw","token":"0x...","receiver":"0x...","amount":"0x<uint256>"}
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
| ERC20 | `ERC20 OK` |
| ERC721 | `ERC721 OK` |
| ERC1155 single | `1155S OK` |
| ERC1155 batch | `1155B OK` |

### Note on withdrawals and balance tracking

This dapp is a **test tool** — it does not track balances. Every withdrawal command emits a voucher unconditionally. If the application contract does not actually hold the asset on-chain, the voucher will revert when executed on L1. This is the expected, correct Cartesi model: balance enforcement happens at L1 execution time, not at dapp logic time.

The test suite verifies:
- Valid advances are accepted and vouchers are correctly formed (suite 05)
- Attempting a withdrawal without a prior deposit still emits a voucher (suite 06)
- After epoch finalization, vouchers can be executed on L1 and L1 balances change correctly (suite 08)
- Notices can be validated against the on-chain Merkle root (suite 08)

---

## Output size limits

| Output | Max payload |
|---|---|
| Notice | 2,097,152 bytes (2 MB) |
| Report | 2,097,152 bytes (2 MB) |
| Voucher calldata | 2,097,152 bytes (2 MB) |

Exceeding the limit causes the rollup server to reject the `/notice` or `/report` POST, which this dapp propagates as a rejected advance input for notices, and as a silently truncated run (no more reports) for inspect.
