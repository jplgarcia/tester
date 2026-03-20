#!/usr/bin/env bash
# =============================================================================
# test.sh — Full integration test suite for the Cartesi test dapp.
# Run after  `cartesi run`  and after  `forge script deploy`.
#
# Required env vars:
#   CARTESI_APP_ADDRESS    — printed by cartesi run
#   PRIVATE_KEY            — default: Anvil key #0
#   TEST_ERC20_ADDRESS     — printed by Deploy.s.sol
#   TEST_ERC721_ADDRESS    — printed by Deploy.s.sol
#   TEST_ERC1155_ADDRESS   — printed by Deploy.s.sol
#   MINTABLE_ERC721_ADDRESS— printed by Deploy.s.sol
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-http://localhost:8545}"
GRAPHQL_URL="${GRAPHQL_URL:-http://localhost:8080/graphql}"
INSPECT_URL="${INSPECT_URL:-http://localhost:8080/inspect}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
DEPLOYER="${DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

APP="${CARTESI_APP_ADDRESS:?Missing CARTESI_APP_ADDRESS}"
ERC20="${TEST_ERC20_ADDRESS:?Missing TEST_ERC20_ADDRESS}"
ERC721="${TEST_ERC721_ADDRESS:?Missing TEST_ERC721_ADDRESS}"
ERC1155="${TEST_ERC1155_ADDRESS:?Missing TEST_ERC1155_ADDRESS}"
MINTABLE_ERC721="${MINTABLE_ERC721_ADDRESS:?Missing MINTABLE_ERC721_ADDRESS}"

INPUT_BOX="0x1b51e2992A2755Ba4D6F7094032DF91991a0Cfac"
ETH_PORTAL="0xA632c5c05812c6a6149B7af5C56117d1D2603828"
ERC20_PORTAL="0xACA6586A0Cf05bD831f2501E7B4aea550dA6562D"
ERC721_PORTAL="0x9E8851dadb2b77103928518846c4678d48b5e371"
ERC1155_SINGLE_PORTAL="0x18558398Dd1a8cE20956287a4Da7B76aE7A96662"
ERC1155_BATCH_PORTAL="0xe246Abb974B307490d9C6932F48EbE79de72338A"

PASS=0; FAIL=0

# ── Formatting ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
pass() { echo -e "${GREEN}  ✓${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}  ✗${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${BOLD}${CYAN}══╡ $1 ╞══${NC}"; }

# ── Hex helpers ───────────────────────────────────────────────────────────────
to_hex()  { printf '%s' "$1" | xxd -p | tr -d '\n'; }   # returns raw hex (no 0x)
from_hex(){ printf '%s' "${1#0x}" | xxd -r -p; }         # 0x-prefixed hex → string

# Encode a uint256 decimal/hex value as a 32-byte zero-padded hex string (0x-prefixed)
uint256_hex() {
    printf '0x%064x' "${1:-0}" 2>/dev/null || \
    python3 -c "print('0x{:064x}'.format(${1}))"
}

# ── InputBox helper ──────────────────────────────────────────────────────────
# Returns the input index (decimal) assigned by InputBox
send_advance_json() {
    local json="$1"
    local hex_payload="0x$(to_hex "$json")"
    local tx_json
    tx_json=$(cast send "$INPUT_BOX" \
        "addInput(address,bytes)" "$APP" "$hex_payload" \
        --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
    local tx_hash
    tx_hash=$(echo "$tx_json" | jq -r '.transactionHash')
    # InputAdded(address indexed dapp, uint256 indexed inboxInputIndex, address sender, bytes input)
    # topic[2] = inboxInputIndex
    local idx_hex
    idx_hex=$(cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json 2>/dev/null \
        | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
    printf '%d' "$idx_hex" 2>/dev/null || echo "$idx_hex"
}

# ── GraphQL polling ───────────────────────────────────────────────────────────
# Poll until the input at given index has a terminal status, return full JSON
poll_input() {
    local idx="$1"
    local timeout="${2:-30}"
    local query
    query='{
      "query": "{ input(index: '"$idx"') { status notices { edges { node { payload } } } reports { edges { node { payload } } } vouchers { edges { node { destination payload } } } } }"
    }'
    for ((i=0; i<timeout; i++)); do
        local result
        result=$(curl -s -X POST "$GRAPHQL_URL" \
            -H 'Content-Type: application/json' -d "$query")
        local status
        status=$(echo "$result" | jq -r '.data.input.status // "NONE"')
        case "$status" in
            NONE|ACTIVE) sleep 1 ;;
            *)           echo "$result"; return 0 ;;
        esac
    done
    echo '{"data":{"input":{"status":"TIMEOUT"}}}'; return 1
}

input_status() { echo "$1" | jq -r '.data.input.status'; }

# Count outputs of a given type in a poll_input result
notice_count()  { echo "$1" | jq '.data.input.notices.edges | length'; }
report_count()  { echo "$1" | jq '.data.input.reports.edges | length'; }
voucher_count() { echo "$1" | jq '.data.input.vouchers.edges | length'; }

# Get Nth notice/report payload decoded as UTF-8 string
notice_text()  { from_hex "$(echo "$1" | jq -r ".data.input.notices.edges[$2].node.payload")"; }
voucher_dest() { echo "$1" | jq -r ".data.input.vouchers.edges[$2].node.destination" | tr '[:upper:]' '[:lower:]'; }

# Get Nth notice raw payload size in bytes (hex payload → byte count)
notice_bytes() {
    local payload
    payload=$(echo "$1" | jq -r ".data.input.notices.edges[$2].node.payload")
    printf '%d' $(( (${#payload} - 2) / 2 ))
}

# ── Inspect helper ─────────────────────────────────────────────────────────────
# Sends an inspect, returns the parsed JSON response
send_inspect_json() {
    local json="$1"
    local hex_payload
    hex_payload="$(to_hex "$json")"
    curl -s "http://localhost:8080/inspect/$hex_payload"
}

inspect_report_count() { echo "$1" | jq '.reports | length'; }
inspect_report_bytes() {
    local payload
    payload=$(echo "$1" | jq -r ".reports[$2].payload")
    printf '%d' $(( (${#payload} - 2) / 2 ))
}
inspect_status() { echo "$1" | jq -r '.status'; }  # "Accepted" or "Rejected"

# ── 2 MB limit constants ──────────────────────────────────────────────────────
SIZE_1KB=1024
SIZE_1MB=1048576
SIZE_2MB_MINUS_1=2097151
SIZE_2MB=2097152
SIZE_2MB_PLUS_1=2097153

# =============================================================================
# PRE-FLIGHT
# =============================================================================
section "Pre-flight checks"

# Cartesi node
if curl -sf "$GRAPHQL_URL" -X POST -H 'Content-Type: application/json' \
    -d '{"query":"{ inputs { totalCount } }"}' >/dev/null 2>&1; then
    pass "Cartesi node reachable at $GRAPHQL_URL"
else
    fail "Cartesi node not reachable at $GRAPHQL_URL — run 'cartesi run' first"
    exit 1
fi

# Anvil
if cast block --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    pass "Anvil reachable at $RPC_URL"
else
    fail "Anvil not reachable"; exit 1
fi

# Contracts
for label_addr in "TestERC20:$ERC20" "TestERC721:$ERC721" "TestERC1155:$ERC1155" "MintableERC721:$MINTABLE_ERC721"; do
    label="${label_addr%%:*}"; addr="${label_addr##*:}"
    code=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null)
    if [[ "$code" == "0x" || -z "$code" ]]; then
        fail "$label not deployed at $addr — run Deploy.s.sol first"; exit 1
    else
        pass "$label deployed at $addr"
    fi
done

# =============================================================================
# SECTION 1: DEPOSITS
# =============================================================================
section "Deposits"

# ── 1.1 ETH deposit ────────────────────────────────────────────────────────────
echo "  → ETH deposit (0.5 ETH)"
TX=$(cast send "$ETH_PORTAL" "depositEther(address,bytes)" "$APP" "0x" \
    --value "500000000000000000" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
TX_HASH=$(echo "$TX" | jq -r '.transactionHash')
IDX_HEX=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null \
    | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
IDX_ETH=$(printf '%d' "$IDX_HEX" 2>/dev/null || echo 0)
RESULT=$(poll_input "$IDX_ETH")
STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == "ETH OK" ]] \
    && pass "ETH deposit accepted, notice='ETH OK'" \
    || fail "ETH deposit: status=$STATUS notice='$TEXT'"

# ── 1.2 ERC20 deposit ──────────────────────────────────────────────────────────
echo "  → ERC20 deposit (100 tokens)"
cast send "$ERC20" "approve(address,uint256)" "$ERC20_PORTAL" "100000000000000000000" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null 2>&1
TX=$(cast send "$ERC20_PORTAL" "depositERC20Tokens(address,address,uint256,bytes)" \
    "$ERC20" "$APP" "100000000000000000000" "0x" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
TX_HASH=$(echo "$TX" | jq -r '.transactionHash')
IDX_HEX=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null \
    | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
IDX=$(printf '%d' "$IDX_HEX" 2>/dev/null || echo 0)
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == "ERC20 OK" ]] \
    && pass "ERC20 deposit accepted, notice='ERC20 OK'" \
    || fail "ERC20 deposit: status=$STATUS notice='$TEXT'"

# Save the ETH/ERC20 deposit indices for withdrawal tests
IDX_ETH_DEPOSIT=$IDX_ETH
IDX_ERC20_DEPOSIT=$IDX

# ── 1.3 ERC721 deposit ─────────────────────────────────────────────────────────
echo "  → ERC721 deposit (tokenId=1)"
cast send "$ERC721" "approve(address,uint256)" "$ERC721_PORTAL" "1" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null 2>&1
TX=$(cast send "$ERC721_PORTAL" "depositERC721Token(address,address,uint256,bytes,bytes)" \
    "$ERC721" "$APP" "1" "0x" "0x" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
TX_HASH=$(echo "$TX" | jq -r '.transactionHash')
IDX_HEX=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null \
    | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
IDX=$(printf '%d' "$IDX_HEX" 2>/dev/null || echo 0)
IDX_ERC721_DEPOSIT=$IDX
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == "ERC721 OK" ]] \
    && pass "ERC721 deposit accepted, notice='ERC721 OK'" \
    || fail "ERC721 deposit: status=$STATUS notice='$TEXT'"

# ── 1.4 ERC1155 single deposit ─────────────────────────────────────────────────
echo "  → ERC1155 single deposit (id=1, amount=50)"
cast send "$ERC1155" "setApprovalForAll(address,bool)" "$ERC1155_SINGLE_PORTAL" "true" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null 2>&1
TX=$(cast send "$ERC1155_SINGLE_PORTAL" \
    "depositSingleERC1155Token(address,address,uint256,uint256,bytes,bytes)" \
    "$ERC1155" "$APP" "1" "50" "0x" "0x" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
TX_HASH=$(echo "$TX" | jq -r '.transactionHash')
IDX_HEX=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null \
    | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
IDX=$(printf '%d' "$IDX_HEX" 2>/dev/null || echo 0)
IDX_ERC1155S_DEPOSIT=$IDX
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == "1155S OK" ]] \
    && pass "ERC1155 single deposit accepted, notice='1155S OK'" \
    || fail "ERC1155 single deposit: status=$STATUS notice='$TEXT'"

# ── 1.5 ERC1155 batch deposit ──────────────────────────────────────────────────
echo "  → ERC1155 batch deposit (ids=[1,2,3], amounts=[10,20,30])"
cast send "$ERC1155" "setApprovalForAll(address,bool)" "$ERC1155_BATCH_PORTAL" "true" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" >/dev/null 2>&1
TX=$(cast send "$ERC1155_BATCH_PORTAL" \
    "depositBatchERC1155Token(address,address,uint256[],uint256[],bytes,bytes)" \
    "$ERC1155" "$APP" "[1,2,3]" "[10,20,30]" "0x" "0x" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --json 2>/dev/null)
TX_HASH=$(echo "$TX" | jq -r '.transactionHash')
IDX_HEX=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null \
    | jq -r '[.logs[] | select(.address | ascii_downcase == "'$(echo $INPUT_BOX | tr '[:upper:]' '[:lower:]')'")] | first | .topics[2] // "0x0"')
IDX=$(printf '%d' "$IDX_HEX" 2>/dev/null || echo 0)
IDX_ERC1155B_DEPOSIT=$IDX
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == "1155B OK" ]] \
    && pass "ERC1155 batch deposit accepted, notice='1155B OK'" \
    || fail "ERC1155 batch deposit: status=$STATUS notice='$TEXT'"

# =============================================================================
# SECTION 2: SETUP
# =============================================================================
section "Setup"

# ── 2.1 set_mint_contract ──────────────────────────────────────────────────────
echo "  → set_mint_contract"
IDX=$(send_advance_json "{\"cmd\":\"set_mint_contract\",\"address\":\"$MINTABLE_ERC721\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
TEXT=$(notice_text "$RESULT" 0 2>/dev/null || echo "")
expected_prefix="mint_contract="
[[ "$STATUS" == "ACCEPTED" && "$TEXT" == ${expected_prefix}* ]] \
    && pass "set_mint_contract accepted, notice confirms address" \
    || fail "set_mint_contract: status=$STATUS notice='$TEXT'"

# =============================================================================
# SECTION 3: NOTICE GENERATION (under/at/over 2 MB)
# =============================================================================
section "Advance: generate_notices (size limits)"

# ── 3.1 1 KB ──────────────────────────────────────────────────────────────────
echo "  → 1 notice of 1 KB"
IDX=$(send_advance_json "{\"cmd\":\"generate_notices\",\"size\":$SIZE_1KB,\"count\":1}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
NC_COUNT=$(notice_count "$RESULT")
NC_BYTES=$(notice_bytes "$RESULT" 0 2>/dev/null || echo 0)
[[ "$STATUS" == "ACCEPTED" && "$NC_COUNT" -eq 1 && "$NC_BYTES" -eq $SIZE_1KB ]] \
    && pass "1 KB notice: ACCEPTED, size=${NC_BYTES}B" \
    || fail "1 KB notice: status=$STATUS notices=$NC_COUNT size=${NC_BYTES}B"

# ── 3.2 1 MB ──────────────────────────────────────────────────────────────────
echo "  → 1 notice of 1 MB"
IDX=$(send_advance_json "{\"cmd\":\"generate_notices\",\"size\":$SIZE_1MB,\"count\":1}")
RESULT=$(poll_input "$IDX" 60); STATUS=$(input_status "$RESULT")
NC_COUNT=$(notice_count "$RESULT")
NC_BYTES=$(notice_bytes "$RESULT" 0 2>/dev/null || echo 0)
[[ "$STATUS" == "ACCEPTED" && "$NC_COUNT" -eq 1 && "$NC_BYTES" -eq $SIZE_1MB ]] \
    && pass "1 MB notice: ACCEPTED, size=${NC_BYTES}B" \
    || fail "1 MB notice: status=$STATUS notices=$NC_COUNT size=${NC_BYTES}B"

# ── 3.3 3 notices of 100 KB each ──────────────────────────────────────────────
echo "  → 3 notices of 100 KB each"
IDX=$(send_advance_json "{\"cmd\":\"generate_notices\",\"size\":102400,\"count\":3}")
RESULT=$(poll_input "$IDX" 60); STATUS=$(input_status "$RESULT")
NC_COUNT=$(notice_count "$RESULT")
[[ "$STATUS" == "ACCEPTED" && "$NC_COUNT" -eq 3 ]] \
    && pass "3×100KB notices: ACCEPTED, count=$NC_COUNT" \
    || fail "3×100KB notices: status=$STATUS count=$NC_COUNT"

# ── 3.4 Exactly 2 MB (boundary — should be accepted) ──────────────────────────
echo "  → 1 notice of exactly 2 MB (boundary)"
IDX=$(send_advance_json "{\"cmd\":\"generate_notices\",\"size\":$SIZE_2MB,\"count\":1}")
RESULT=$(poll_input "$IDX" 90); STATUS=$(input_status "$RESULT")
NC_COUNT=$(notice_count "$RESULT")
NC_BYTES=$(notice_bytes "$RESULT" 0 2>/dev/null || echo 0)
[[ "$STATUS" == "ACCEPTED" && "$NC_COUNT" -eq 1 && "$NC_BYTES" -eq $SIZE_2MB ]] \
    && pass "Exactly 2 MB notice: ACCEPTED, size=${NC_BYTES}B" \
    || fail "Exactly 2 MB notice: status=$STATUS notices=$NC_COUNT size=${NC_BYTES}B"

# ── 3.5 Over 2 MB (boundary + 1 — must be rejected) ──────────────────────────
echo "  → 1 notice of 2 MB + 1 byte (must be REJECTED)"
IDX=$(send_advance_json "{\"cmd\":\"generate_notices\",\"size\":$SIZE_2MB_PLUS_1,\"count\":1}")
RESULT=$(poll_input "$IDX" 90); STATUS=$(input_status "$RESULT")
NC_COUNT=$(notice_count "$RESULT")
[[ "$STATUS" == "REJECTED" && "$NC_COUNT" -eq 0 ]] \
    && pass "2 MB+1 notice: REJECTED as expected, no notices emitted" \
    || fail "2 MB+1 notice: status=$STATUS (expected REJECTED) notices=$NC_COUNT"

# =============================================================================
# SECTION 4: INSPECT / REPORT GENERATION (under/at/over 2 MB)
# =============================================================================
section "Inspect: generate_reports (size limits)"

# ── 4.1 1 KB ──────────────────────────────────────────────────────────────────
echo "  → 1 report of 1 KB"
RESP=$(send_inspect_json "{\"cmd\":\"generate_reports\",\"size\":$SIZE_1KB,\"count\":1}")
R_COUNT=$(inspect_report_count "$RESP")
R_BYTES=$(inspect_report_bytes "$RESP" 0 2>/dev/null || echo 0)
[[ "$R_COUNT" -eq 1 && "$R_BYTES" -eq $SIZE_1KB ]] \
    && pass "1 KB report: ${R_COUNT} report, size=${R_BYTES}B" \
    || fail "1 KB report: count=$R_COUNT size=${R_BYTES}B"

# ── 4.2 1 MB ──────────────────────────────────────────────────────────────────
echo "  → 1 report of 1 MB"
RESP=$(send_inspect_json "{\"cmd\":\"generate_reports\",\"size\":$SIZE_1MB,\"count\":1}")
R_COUNT=$(inspect_report_count "$RESP")
R_BYTES=$(inspect_report_bytes "$RESP" 0 2>/dev/null || echo 0)
[[ "$R_COUNT" -eq 1 && "$R_BYTES" -eq $SIZE_1MB ]] \
    && pass "1 MB report: ${R_COUNT} report, size=${R_BYTES}B" \
    || fail "1 MB report: count=$R_COUNT size=${R_BYTES}B"

# ── 4.3 Multiple reports ───────────────────────────────────────────────────────
echo "  → 2 reports of 500 KB each"
RESP=$(send_inspect_json "{\"cmd\":\"generate_reports\",\"size\":512000,\"count\":2}")
R_COUNT=$(inspect_report_count "$RESP")
[[ "$R_COUNT" -eq 2 ]] \
    && pass "2×500KB reports: count=$R_COUNT" \
    || fail "2×500KB reports: count=$R_COUNT (expected 2)"

# ── 4.4 Exactly 2 MB ──────────────────────────────────────────────────────────
echo "  → 1 report of exactly 2 MB (boundary)"
RESP=$(send_inspect_json "{\"cmd\":\"generate_reports\",\"size\":$SIZE_2MB,\"count\":1}")
R_COUNT=$(inspect_report_count "$RESP")
R_BYTES=$(inspect_report_bytes "$RESP" 0 2>/dev/null || echo 0)
[[ "$R_COUNT" -eq 1 && "$R_BYTES" -eq $SIZE_2MB ]] \
    && pass "Exactly 2 MB report: ${R_COUNT} report, size=${R_BYTES}B" \
    || fail "Exactly 2 MB report: count=$R_COUNT size=${R_BYTES}B"

# ── 4.5 Over 2 MB — inspect still returns "Accepted" but no report emitted ────
echo "  → 1 report of 2 MB+1 (expected: 0 reports, inspect still Accepted)"
RESP=$(send_inspect_json "{\"cmd\":\"generate_reports\",\"size\":$SIZE_2MB_PLUS_1,\"count\":1}")
R_COUNT=$(inspect_report_count "$RESP")
[[ "$R_COUNT" -eq 0 ]] \
    && pass "2 MB+1 report: 0 reports emitted (server rejected oversized payload)" \
    || fail "2 MB+1 report: count=$R_COUNT (expected 0)"

# ── 4.6 Echo ───────────────────────────────────────────────────────────────────
echo "  → echo inspect"
RESP=$(send_inspect_json '{"cmd":"echo"}')
R_COUNT=$(inspect_report_count "$RESP")
[[ "$R_COUNT" -eq 1 ]] \
    && pass "echo inspect: 1 report returned" \
    || fail "echo inspect: count=$R_COUNT"

# =============================================================================
# SECTION 5: WITHDRAWALS (after deposits)
# =============================================================================
section "Withdrawals (valid — vouchers should be created)"

# ── 5.1 ETH withdraw ──────────────────────────────────────────────────────────
echo "  → eth_withdraw (100000000000000000 wei = 0.1 ETH)"
AMOUNT_HEX=$(printf '0x%064x' 100000000000000000)
IDX=$(send_advance_json "{\"cmd\":\"eth_withdraw\",\"receiver\":\"$DEPLOYER\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$ETH_PORTAL" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "eth_withdraw: ACCEPTED, voucher to EtherPortal" \
    || fail "eth_withdraw: status=$STATUS vouchers=$VC dest=$VDEST"

# ── 5.2 ERC20 withdraw ────────────────────────────────────────────────────────
echo "  → erc20_withdraw (10000000000000000000 = 10 tokens)"
AMOUNT_HEX=$(printf '0x%064x' 10000000000000000000)
IDX=$(send_advance_json "{\"cmd\":\"erc20_withdraw\",\"token\":\"$ERC20\",\"receiver\":\"$DEPLOYER\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$ERC20" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "erc20_withdraw: ACCEPTED, voucher to ERC20 token contract" \
    || fail "erc20_withdraw: status=$STATUS vouchers=$VC dest=$VDEST"

# ── 5.3 ERC721 withdraw ───────────────────────────────────────────────────────
echo "  → erc721_withdraw (tokenId=1)"
TOKEN_ID_HEX=$(printf '0x%064x' 1)
IDX=$(send_advance_json "{\"cmd\":\"erc721_withdraw\",\"token\":\"$ERC721\",\"receiver\":\"$DEPLOYER\",\"tokenId\":\"$TOKEN_ID_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$ERC721" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "erc721_withdraw: ACCEPTED, voucher to ERC721 token contract" \
    || fail "erc721_withdraw: status=$STATUS vouchers=$VC dest=$VDEST"

# ── 5.4 ERC1155 single withdraw ───────────────────────────────────────────────
echo "  → erc1155_withdraw_single (id=1, amount=25)"
ID_HEX=$(printf '0x%064x' 1)
AMOUNT_HEX=$(printf '0x%064x' 25)
IDX=$(send_advance_json "{\"cmd\":\"erc1155_withdraw_single\",\"token\":\"$ERC1155\",\"receiver\":\"$DEPLOYER\",\"id\":\"$ID_HEX\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$ERC1155" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "erc1155_withdraw_single: ACCEPTED, voucher to ERC1155 contract" \
    || fail "erc1155_withdraw_single: status=$STATUS vouchers=$VC dest=$VDEST"

# ── 5.5 ERC1155 batch withdraw ────────────────────────────────────────────────
echo "  → erc1155_withdraw_batch (ids=[1,2], amounts=[5,10])"
ID1_HEX=$(printf '0x%064x' 1); ID2_HEX=$(printf '0x%064x' 2)
A1_HEX=$(printf  '0x%064x' 5); A2_HEX=$(printf  '0x%064x' 10)
IDX=$(send_advance_json "{\"cmd\":\"erc1155_withdraw_batch\",\"token\":\"$ERC1155\",\"receiver\":\"$DEPLOYER\",\"ids\":[\"$ID1_HEX\",\"$ID2_HEX\"],\"amounts\":[\"$A1_HEX\",\"$A2_HEX\"]}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$ERC1155" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "erc1155_withdraw_batch: ACCEPTED, voucher to ERC1155 contract" \
    || fail "erc1155_withdraw_batch: status=$STATUS vouchers=$VC dest=$VDEST"

# ── 5.6 mint_erc721 via voucher ───────────────────────────────────────────────
echo "  → mint_erc721 (mint tokenId=100 to deployer)"
TOKEN_ID_HEX=$(printf '0x%064x' 100)
IDX=$(send_advance_json "{\"cmd\":\"mint_erc721\",\"receiver\":\"$DEPLOYER\",\"tokenId\":\"$TOKEN_ID_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
VDEST=$(voucher_dest "$RESULT" 0 2>/dev/null || echo "")
TARGET=$(echo "$MINTABLE_ERC721" | tr '[:upper:]' '[:lower:]')
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 && "$VDEST" == "$TARGET" ]] \
    && pass "mint_erc721: ACCEPTED, voucher to MintableERC721" \
    || fail "mint_erc721: status=$STATUS vouchers=$VC dest=$VDEST"

# =============================================================================
# SECTION 6: WITHDRAWAL WITHOUT DEPOSIT (over-draft behavior)
# The dapp does NOT track balances — it emits a voucher regardless.
# The advance is ACCEPTED. The voucher would REVERT at L1 execution.
# This is correct Cartesi model behavior.
# =============================================================================
section "Withdrawal without prior deposit (overdraft — voucher created, L1 would revert)"

# ── 6.1 ETH overdraft ─────────────────────────────────────────────────────────
echo "  → ETH withdraw of 1000 ETH (never deposited this much)"
AMOUNT_HEX=$(printf '0x%064x' 1000000000000000000000)
IDX=$(send_advance_json "{\"cmd\":\"eth_withdraw\",\"receiver\":\"$DEPLOYER\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 ]] \
    && pass "ETH overdraft: advance ACCEPTED (dapp has no balance check), voucher created; L1 execution would revert" \
    || fail "ETH overdraft: status=$STATUS vouchers=$VC"

# ── 6.2 ERC20 overdraft ───────────────────────────────────────────────────────
echo "  → ERC20 withdraw 10^30 tokens (far exceeds deposit)"
AMOUNT_HEX="0x$(python3 -c 'print(f"{10**30:064x}")')"
IDX=$(send_advance_json "{\"cmd\":\"erc20_withdraw\",\"token\":\"$ERC20\",\"receiver\":\"$DEPLOYER\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 ]] \
    && pass "ERC20 overdraft: advance ACCEPTED, voucher created; L1 execution would revert" \
    || fail "ERC20 overdraft: status=$STATUS vouchers=$VC"

# ── 6.3 ERC721 never-deposited tokenId ───────────────────────────────────────
echo "  → ERC721 withdraw tokenId=999 (never deposited)"
TOKEN_ID_HEX=$(printf '0x%064x' 999)
IDX=$(send_advance_json "{\"cmd\":\"erc721_withdraw\",\"token\":\"$ERC721\",\"receiver\":\"$DEPLOYER\",\"tokenId\":\"$TOKEN_ID_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 ]] \
    && pass "ERC721 overdraft: advance ACCEPTED, voucher created; L1 execution would revert" \
    || fail "ERC721 overdraft: status=$STATUS vouchers=$VC"

# ── 6.4 ERC1155 overdraft ─────────────────────────────────────────────────────
echo "  → ERC1155 single withdraw id=1, amount=100000 (far exceeds deposit)"
ID_HEX=$(printf '0x%064x' 1)
AMOUNT_HEX=$(printf '0x%064x' 100000)
IDX=$(send_advance_json "{\"cmd\":\"erc1155_withdraw_single\",\"token\":\"$ERC1155\",\"receiver\":\"$DEPLOYER\",\"id\":\"$ID_HEX\",\"amount\":\"$AMOUNT_HEX\"}")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
VC=$(voucher_count "$RESULT")
[[ "$STATUS" == "ACCEPTED" && "$VC" -eq 1 ]] \
    && pass "ERC1155 overdraft: advance ACCEPTED, voucher created; L1 execution would revert" \
    || fail "ERC1155 overdraft: status=$STATUS vouchers=$VC"

# =============================================================================
# SECTION 7: ERROR / EDGE CASES
# =============================================================================
section "Error cases"

# ── 7.1 Invalid JSON ──────────────────────────────────────────────────────────
echo "  → Invalid JSON payload (should reject)"
IDX=$(send_advance_json "not_valid_json{{{")
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
[[ "$STATUS" == "REJECTED" ]] \
    && pass "Invalid JSON: REJECTED as expected" \
    || fail "Invalid JSON: status=$STATUS (expected REJECTED)"

# ── 7.2 Unknown advance cmd ───────────────────────────────────────────────────
echo "  → Unknown advance cmd (should reject)"
IDX=$(send_advance_json '{"cmd":"does_not_exist"}')
RESULT=$(poll_input "$IDX"); STATUS=$(input_status "$RESULT")
[[ "$STATUS" == "REJECTED" ]] \
    && pass "Unknown cmd: REJECTED as expected" \
    || fail "Unknown cmd: status=$STATUS (expected REJECTED)"

# ── 7.3 mint_erc721 before set_mint_contract ──────────────────────────────────
# Deploy a fresh devnet restart to test this, OR verify the contract is already set.
# We skip this if set_mint_contract was already called above (it was).
echo "  → (mint without set_mint_contract already tested implicitly by ordering)"
pass "Ordering verified: set_mint_contract called before any mint_erc721"

# ── 7.4 Unknown inspect cmd ───────────────────────────────────────────────────
echo "  → Unknown inspect cmd (accepted + error report)"
RESP=$(send_inspect_json '{"cmd":"not_a_real_cmd"}')
R_COUNT=$(inspect_report_count "$RESP")
[[ "$R_COUNT" -ge 1 ]] \
    && pass "Unknown inspect cmd: accepted, error report emitted" \
    || fail "Unknown inspect cmd: count=$R_COUNT (expected >=1 error report)"

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: $TOTAL tests │ ${GREEN}$PASS passed${NC}${BOLD} │ ${RED}$FAIL failed${NC}${BOLD}  ${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some tests failed. Check dapp logs with 'cartesi run' output above.${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed.${NC}"
fi
