// =============================================================================
// Cartesi v2.0 Test DApp
//
// Talks to the Cartesi Machine through libcmt (machine-guest-tools), not
// through rollup-http-server: outputs are written straight into the CMIO
// transmit buffer, so the only size limit is the 2 MiB buffer itself.
//
// Advance commands (payload = UTF-8 JSON bytes):
//   {"cmd":"set_mint_contract","address":"0x..."}
//   {"cmd":"generate_notices","size":<bytes>,"count":<n>}
//   {"cmd":"eth_withdraw","receiver":"0x...","amount":"0x<uint256>"}
//   {"cmd":"erc20_withdraw","token":"0x...","receiver":"0x...","amount":"0x<uint256>"}
//   {"cmd":"erc721_withdraw","token":"0x...","receiver":"0x...","tokenId":"0x<uint256>"}
//   {"cmd":"erc1155_withdraw_single","token":"0x...","receiver":"0x...","id":"0x<uint256>","amount":"0x<uint256>"}
//   {"cmd":"erc1155_withdraw_batch","token":"0x...","receiver":"0x...","ids":["0x..."],"amounts":["0x..."]}
//   {"cmd":"mint_erc721","receiver":"0x...","tokenId":"0x<uint256>"}
//   {"cmd":"delegate_erc20_transfer","logic":"0x...","token":"0x...","receiver":"0x...","amount":"0x<uint256>"}
//   {"cmd":"delegate_erc20_transfer_targeted","logic":"0x...","token":"0x...","receiver":"0x...","amount":"0x<uint256>","allowedExecutor":"0x..."}
//   {"cmd":"force_exception","message":"..."}   → exception yield (input status EXCEPTION)
//   {"cmd":"advance_reports","size":<bytes>,"count":<n>}
//   {"cmd":"mixed_outputs","token":"0x...","receiver":"0x...","amount":"0x...", optional noticeText, reportText}
//   {"cmd":"multi_erc20_withdraw","token":"0x...","receiver":"0x...","amountFirst":"0x...","amountSecond":"0x..."}
//   {"cmd":"large_voucher","destination":"0x...","payloadBytes":<n>}
//   erc20_withdraw optional: "valueField":"omit"|"zero_hash"
//   force_exception optional: "hex":"0x..." (raw exception payload instead of message)
//
// QA commands (advance):
//   {"cmd":"emit_blob","size":<bytes>[,"prefix":"0x.."][,"count":<n>]}   raw output(s), pattern i & 0xff
//   {"cmd":"emit_blob","hex":"0x..."[,"count":<n>]}                      raw output(s) with exactly these bytes
//   {"cmd":"emit_reports","count":<n>[,"size":<bytes>=16]}
//   {"cmd":"emit_notices","count":<n>[,"size":<bytes>=16]}
//   {"cmd":"emit_notice_exact","size":<bytes>}   one notice with exactly <bytes> of payload + a report
//   {"cmd":"voucher","destination":"0x..","payload":"0x..",["value":"0x.."]}
//   {"cmd":"delegate_voucher","destination":"0x..","payload":"0x.."}
//   {"cmd":"reject"} | {"cmd":"halt"} | {"cmd":"unexpected_yield"}
//   {"cmd":"invalid_outputs_root"} | {"cmd":"invalid_outputs_root_length"}
//   {"cmd":"seq","steps":[{...},{...}]}          run commands in order, stop at the first non-accept
// A QA command that cannot emit its output emits a report with the reason
// (e.g. "rc=-105 (No buffer space available)") and rejects the input.
//
// Deposits are auto-detected by msg_sender matching portal addresses.
// Notices append decoded layer payloads when non-empty: ETH/ERC20 " exec=0x…";
// ERC721 / ERC1155 " base=0x… exec=0x…".
//
// Inspect commands (payload = UTF-8 JSON bytes, optionally wrapped in
// {"payload":"0x<hex of the JSON>"}):
//   {"cmd":"generate_reports","size":<bytes>,"count":<n>}
//   {"cmd":"echo"}  → reports back the raw payload as a report
//   {"cmd":"emit_reports","count":<n>[,"size":<bytes>=16]}
//   {"cmd":"reject"} → Rejected | {"cmd":"force_exception",...} → Exception
//   {"cmd":"halt"} → MachineHalted | {"cmd":"unexpected_yield"} → Failed
//   {"cmd":"seq","steps":[...]}
//
// =============================================================================

#include <stdio.h>
#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <stdexcept>

extern "C" {
#include <libcmt/rollup.h>
}

#include "3rdparty/picojson/picojson.h"

// =============================================================================
// PORTAL ADDRESSES  (Cartesi rollups-contracts v3.0.0-alpha.10, used by
// rollups-node v2.0.0-alpha.13 — deterministic deployment: the same addresses on
// the devnet, Sepolia, Base Sepolia and OP Sepolia; verified on-chain.)
// =============================================================================
static const std::string ADDR_ETH_PORTAL           = "0x035b11be55656c6cfc822d1cae568c1af2e497b0";
static const std::string ADDR_ERC20_PORTAL          = "0x3332de61a8bb9ac84893b2f552fe81c9a6dc5419";
static const std::string ADDR_ERC721_PORTAL         = "0x397c352d18dff47cc8a6143403142cf7afd5ff7e";
static const std::string ADDR_ERC1155_SINGLE_PORTAL = "0x585f56351a66f131e176a345662215c772f80451";
static const std::string ADDR_ERC1155_BATCH_PORTAL  = "0xee33550a22e3cf6cc265524dc9bcfd99d2307ebe";

// =============================================================================
// ABI FUNCTION SELECTORS  (keccak256 of canonical signature, first 4 bytes)
// =============================================================================
// transfer(address,uint256)
static const uint8_t SEL_ERC20_TRANSFER[4]        = {0xa9, 0x05, 0x9c, 0xbb};
// safeTransferFrom(address,address,uint256)
static const uint8_t SEL_ERC721_SAFE_TRANSFER[4]  = {0x42, 0x84, 0x2e, 0x0e};
// safeTransferFrom(address,address,uint256,uint256,bytes)
static const uint8_t SEL_ERC1155_SAFE_TRANSFER[4] = {0xf2, 0x42, 0x43, 0x2a};
// safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)
static const uint8_t SEL_ERC1155_SAFE_BATCH[4]    = {0x2e, 0xb2, 0xc2, 0xd6};
// mint(address,uint256)
static const uint8_t SEL_MINT[4]                  = {0x40, 0xc1, 0x0f, 0x19};
// withdrawEther(address,uint256)  — EtherPortal v2 withdrawal
static const uint8_t SEL_WITHDRAW_ETHER[4]        = {0x52, 0x2f, 0x68, 0x15};
// transferERC20(address,address,uint256)  — DelegateVoucherLogic (delegate-call voucher)
static const uint8_t SEL_DELEGATE_ERC20_TRANSFER[4] = {0x9d, 0xb5, 0xdb, 0xe4};
// transferERC20Targeted(address,address,uint256,address)
static const uint8_t SEL_DELEGATE_ERC20_TARGETED[4] = {0x6d, 0x21, 0x52, 0xb9};

// =============================================================================
// GLOBAL STATE
// =============================================================================
static std::string g_mint_contract; // address of MintableERC721 (set via advance)
static std::string g_app_address;   // self address (from advance metadata)

// =============================================================================
// HEX UTILITIES
// =============================================================================
static uint8_t hex_nibble(char c) {
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
    return 0;
}

static std::vector<uint8_t> hex_to_bytes(const std::string &hex) {
    std::string h = hex;
    if (h.size() >= 2 && h[0] == '0' && (h[1] == 'x' || h[1] == 'X'))
        h = h.substr(2);
    if (h.size() % 2 != 0) h = "0" + h;
    std::vector<uint8_t> bytes;
    bytes.reserve(h.size() / 2);
    for (size_t i = 0; i + 1 < h.size(); i += 2)
        bytes.push_back((uint8_t)((hex_nibble(h[i]) << 4) | hex_nibble(h[i + 1])));
    return bytes;
}

static std::string bytes_to_hex(const std::vector<uint8_t> &bytes, bool prefix = true) {
    static const char *hc = "0123456789abcdef";
    std::string r = prefix ? "0x" : "";
    r.reserve(r.size() + bytes.size() * 2);
    for (uint8_t b : bytes) {
        r += hc[(b >> 4) & 0xf];
        r += hc[b & 0xf];
    }
    return r;
}

static std::string to_lower(const std::string &s) {
    std::string r = s;
    std::transform(r.begin(), r.end(), r.begin(), ::tolower);
    return r;
}

// =============================================================================
// ABI ENCODING
// =============================================================================

// Left-pad val into a 32-byte ABI word
static std::vector<uint8_t> abi_word(const std::vector<uint8_t> &val) {
    std::vector<uint8_t> w(32, 0);
    size_t offset = (val.size() < 32) ? (32 - val.size()) : 0;
    for (size_t i = 0; i < val.size() && (offset + i) < 32; i++)
        w[offset + i] = val[i];
    return w;
}

static std::vector<uint8_t> abi_encode_address(const std::string &addr) {
    return abi_word(hex_to_bytes(addr));
}

static std::vector<uint8_t> abi_encode_uint256(const std::string &hex_val) {
    return abi_word(hex_to_bytes(hex_val));
}

static std::vector<uint8_t> abi_encode_uint64(uint64_t v) {
    std::vector<uint8_t> w(32, 0);
    for (int i = 0; i < 8; i++)
        w[31 - i] = (uint8_t)((v >> (8 * i)) & 0xff);
    return w;
}

static void append(std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
    dst.insert(dst.end(), src.begin(), src.end());
}

static void append_sel(std::vector<uint8_t> &dst, const uint8_t sel[4]) {
    dst.insert(dst.end(), sel, sel + 4);
}

// Encode `bytes memory` (length word + data padded to 32-byte boundary)
static std::vector<uint8_t> abi_encode_bytes_value(const std::vector<uint8_t> &data) {
    std::vector<uint8_t> r;
    append(r, abi_encode_uint64((uint64_t)data.size()));
    append(r, data);
    size_t rem = data.size() % 32;
    if (rem != 0) {
        std::vector<uint8_t> pad(32 - rem, 0);
        append(r, pad);
    }
    return r;
}

// Encode uint256[] (length word + elements)
static std::vector<uint8_t> abi_encode_uint256_array_value(const std::vector<std::string> &vals) {
    std::vector<uint8_t> r;
    append(r, abi_encode_uint64((uint64_t)vals.size()));
    for (const auto &v : vals)
        append(r, abi_encode_uint256(v));
    return r;
}

// ── Voucher payload builders ─────────────────────────────────────────────────

// ERC20: transfer(address to, uint256 amount)
static std::vector<uint8_t> build_erc20_transfer(
    const std::string &to, const std::string &amount)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_ERC20_TRANSFER);
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(amount));
    return r;
}

// DelegateVoucherLogic: transferERC20(address token, address to, uint256 amount)
static std::vector<uint8_t> build_delegate_erc20_transfer(
    const std::string &token, const std::string &to, const std::string &amount)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_DELEGATE_ERC20_TRANSFER);
    append(r, abi_encode_address(token));
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(amount));
    return r;
}

// DelegateVoucherLogic: transferERC20Targeted(token, to, amount, allowedExecutor)
static std::vector<uint8_t> build_delegate_erc20_targeted(
    const std::string &token,
    const std::string &to,
    const std::string &amount,
    const std::string &allowed_executor)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_DELEGATE_ERC20_TARGETED);
    append(r, abi_encode_address(token));
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(amount));
    append(r, abi_encode_address(allowed_executor));
    return r;
}

// ERC721: safeTransferFrom(address from, address to, uint256 tokenId)
static std::vector<uint8_t> build_erc721_safe_transfer(
    const std::string &from, const std::string &to, const std::string &token_id)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_ERC721_SAFE_TRANSFER);
    append(r, abi_encode_address(from));
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(token_id));
    return r;
}

// ERC1155 single: safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)
static std::vector<uint8_t> build_erc1155_safe_transfer(
    const std::string &from, const std::string &to,
    const std::string &id, const std::string &amount)
{
    // Static: from(32) to(32) id(32) amount(32) bytes_offset(32) = 160
    // Dynamic: bytes value at offset 160
    std::vector<uint8_t> r;
    append_sel(r, SEL_ERC1155_SAFE_TRANSFER);
    append(r, abi_encode_address(from));
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(id));
    append(r, abi_encode_uint256(amount));
    append(r, abi_encode_uint64(160));       // offset = 5 * 32
    append(r, abi_encode_bytes_value({}));   // empty bytes
    return r;
}

// ERC1155 batch: safeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts, bytes data)
static std::vector<uint8_t> build_erc1155_safe_batch(
    const std::string &from, const std::string &to,
    const std::vector<std::string> &ids,
    const std::vector<std::string> &amounts)
{
    size_t N = ids.size();
    //  Head (5 static words at 32 bytes each = 160 bytes):
    //    [0]  from
    //    [1]  to
    //    [2]  offset→ids   = 5*32 = 160
    //    [3]  offset→amts  = 160 + 32 + N*32
    //    [4]  offset→data  = 160 + 2*(32 + N*32)
    uint64_t off_ids  = 5 * 32;
    uint64_t off_amts = off_ids  + 32 + (uint64_t)N * 32;
    uint64_t off_data = off_amts + 32 + (uint64_t)N * 32;

    std::vector<uint8_t> r;
    append_sel(r, SEL_ERC1155_SAFE_BATCH);
    append(r, abi_encode_address(from));
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint64(off_ids));
    append(r, abi_encode_uint64(off_amts));
    append(r, abi_encode_uint64(off_data));
    append(r, abi_encode_uint256_array_value(ids));
    append(r, abi_encode_uint256_array_value(amounts));
    append(r, abi_encode_bytes_value({}));
    return r;
}

// MintableERC721: mint(address to, uint256 tokenId)
static std::vector<uint8_t> build_erc721_mint(
    const std::string &to, const std::string &token_id)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_MINT);
    append(r, abi_encode_address(to));
    append(r, abi_encode_uint256(token_id));
    return r;
}

// EtherPortal: withdrawEther(address receiver, uint256 amount)
static std::vector<uint8_t> build_eth_withdraw(
    const std::string &receiver, const std::string &amount)
{
    std::vector<uint8_t> r;
    append_sel(r, SEL_WITHDRAW_ETHER);
    append(r, abi_encode_address(receiver));
    append(r, abi_encode_uint256(amount));
    return r;
}

// =============================================================================
// ROLLUP I/O (libcmt)
// =============================================================================
// Every emit returns true on success and false when libcmt refuses the output
// (e.g. -ENOBUFS: the encoded output does not fit the 2 MiB CMIO tx buffer).
// The last return code is kept in g_last_rc so callers can report it.
static cmt_rollup_t g_rollup;
static int g_last_rc = 0;

static std::vector<uint8_t> str_bytes(const std::string &s) {
    return std::vector<uint8_t>(s.begin(), s.end());
}

static cmt_abi_bytes_t abi_bytes(const std::vector<uint8_t> &v) {
    cmt_abi_bytes_t b;
    b.length = v.size();
    b.data = (void *)v.data();
    return b;
}

static bool check_rc(const char *what, int rc) {
    g_last_rc = rc;
    if (rc == 0) return true;
    std::cerr << "[" << what << "] emit failed rc=" << rc << " (" << strerror(-rc) << ")\n";
    return false;
}

// 20-byte address from hex; false if it is not exactly 20 bytes.
static bool parse_address(const std::string &hex, cmt_abi_address_t &out) {
    std::vector<uint8_t> b = hex_to_bytes(hex);
    if (b.size() != CMT_ABI_ADDRESS_LENGTH) return false;
    memcpy(out.data, b.data(), CMT_ABI_ADDRESS_LENGTH);
    return true;
}

// Big-endian uint256 from hex (left-padded); false if it needs more than 32 bytes.
static bool parse_u256(const std::string &hex, cmt_abi_u256_t &out) {
    std::vector<uint8_t> b = hex_to_bytes(hex);
    size_t skip = 0;
    while (b.size() - skip > CMT_ABI_U256_LENGTH && b[skip] == 0) skip++;
    if (b.size() - skip > CMT_ABI_U256_LENGTH) return false;
    memset(out.data, 0, CMT_ABI_U256_LENGTH);
    memcpy(out.data + CMT_ABI_U256_LENGTH - (b.size() - skip), b.data() + skip, b.size() - skip);
    return true;
}

static bool emit_notice(const std::vector<uint8_t> &payload) {
    cmt_abi_bytes_t p = abi_bytes(payload);
    return check_rc("notice", cmt_rollup_emit_notice(&g_rollup, &p, nullptr));
}

static bool emit_report(const std::vector<uint8_t> &payload) {
    cmt_abi_bytes_t p = abi_bytes(payload);
    return check_rc("report", cmt_rollup_emit_report(&g_rollup, &p));
}

// Voucher(destination, value, payload). An empty value_hex means value 0.
static bool emit_voucher(const std::string &destination,
                         const std::vector<uint8_t> &payload,
                         const std::string &value_hex = "")
{
    cmt_abi_address_t dst;
    cmt_abi_u256_t value;
    if (!parse_address(destination, dst)) {
        std::cerr << "[voucher] invalid destination " << destination << "\n";
        g_last_rc = -EINVAL;
        return false;
    }
    if (!parse_u256(value_hex, value)) {
        std::cerr << "[voucher] invalid value " << value_hex << "\n";
        g_last_rc = -EINVAL;
        return false;
    }
    cmt_abi_bytes_t p = abi_bytes(payload);
    return check_rc("voucher", cmt_rollup_emit_voucher(&g_rollup, &dst, &value, &p, nullptr));
}

static bool emit_delegate_voucher(const std::string &destination,
                                  const std::vector<uint8_t> &payload)
{
    cmt_abi_address_t dst;
    if (!parse_address(destination, dst)) {
        std::cerr << "[delegate-call-voucher] invalid destination " << destination << "\n";
        g_last_rc = -EINVAL;
        return false;
    }
    cmt_abi_bytes_t p = abi_bytes(payload);
    return check_rc("delegate-call-voucher",
                    cmt_rollup_emit_delegate_call_voucher(&g_rollup, &dst, &p, nullptr));
}

// Exception yield: the node marks the request EXCEPTION (advance: terminal
// GUEST_EXCEPTION; inspect: status "Exception" with exception_data = payload).
static bool emit_exception(const std::vector<uint8_t> &payload) {
    cmt_abi_bytes_t p = abi_bytes(payload);
    return check_rc("exception", cmt_rollup_emit_exception(&g_rollup, &p));
}

// =============================================================================
// DEPOSIT PARSERS
// Rollups v2 InputEncoding.sol (see rollups-contracts):
//   ETH:     abi.encodePacked(sender 20B, value 32B, execLayerData)
//   ERC20:   abi.encodePacked(token 20B, sender 20B, value 32B, execLayerData)
//   ERC721:  abi.encodePacked(token 20B, sender 20B, tokenId 32B, abi.encode(base, exec))
//   1155 S:  abi.encodePacked(token 20B, sender 20B, id 32B, value 32B, abi.encode(base, exec))
//   1155 B:  abi.encodePacked(token 20B, sender 20B, abi.encode(ids[], amts[], base, exec))
// =============================================================================

static std::vector<uint8_t> abi_word_at(const std::vector<uint8_t> &data, size_t offset) {
    if (offset + 32 > data.size()) return std::vector<uint8_t>(32, 0);
    return std::vector<uint8_t>(data.begin() + (ptrdiff_t)offset,
                                data.begin() + (ptrdiff_t)(offset + 32));
}

static std::string word_to_addr(const std::vector<uint8_t> &word) {
    // last 20 bytes of a 32-byte ABI address word
    std::vector<uint8_t> addr(word.begin() + 12, word.end());
    return bytes_to_hex(addr);
}

static std::string word_to_uint256(const std::vector<uint8_t> &word) {
    return bytes_to_hex(word);
}

static uint64_t word_to_uint64(const std::vector<uint8_t> &word) {
    uint64_t v = 0;
    for (int i = 24; i < 32; i++) v = (v << 8) | word[(size_t)i];
    return v;
}

// ABI-encoded `bytes`: length word at `site`, then `length` bytes (32-byte padded).
static std::vector<uint8_t> abi_read_bytes_vector(const std::vector<uint8_t> &p, size_t site) {
    if (site + 32 > p.size()) return {};
    uint64_t len = word_to_uint64(abi_word_at(p, site));
    if (len > 0x1000000u) return {};
    if (site + 32 + len > p.size()) return {};
    return std::vector<uint8_t>(p.begin() + (ptrdiff_t)(site + 32),
                                p.begin() + (ptrdiff_t)(site + 32 + len));
}

// Offset word at `offset_word_pos` points to the length word of a dynamic `bytes` field.
static std::string abi_hex_of_bytes_at_offset_word(const std::vector<uint8_t> &p, size_t offset_word_pos) {
    if (offset_word_pos + 32 > p.size()) return "";
    uint64_t rel = word_to_uint64(abi_word_at(p, offset_word_pos));
    if (rel + 32 > p.size()) return "";
    std::vector<uint8_t> data = abi_read_bytes_vector(p, rel);
    if (data.empty()) return "";
    return bytes_to_hex(data);
}

// abi.encode(bytes baseLayerData, bytes execLayerData) starting at `inner_start`.
static void decode_abi_bytes_pair(const std::vector<uint8_t> &p, size_t inner_start,
                                  std::string &base_hex, std::string &exec_hex) {
    base_hex = "";
    exec_hex = "";
    if (p.size() < inner_start + 64) return;
    uint64_t o0 = word_to_uint64(abi_word_at(p, inner_start + 0));
    uint64_t o1 = word_to_uint64(abi_word_at(p, inner_start + 32));
    if (inner_start + o0 + 32 > p.size() || inner_start + o1 + 32 > p.size()) return;
    std::vector<uint8_t> vb = abi_read_bytes_vector(p, inner_start + o0);
    std::vector<uint8_t> ve = abi_read_bytes_vector(p, inner_start + o1);
    if (!vb.empty()) base_hex = bytes_to_hex(vb);
    if (!ve.empty()) exec_hex = bytes_to_hex(ve);
}

// ETH: encodeEtherDeposit — abi.encodePacked(sender 20B, value 32B, execLayerData)
static void parse_eth_deposit(const std::vector<uint8_t> &p) {
    if (p.size() < 52) { std::cerr << "[ETH deposit] payload too short\n"; return; }
    std::cout << "[ETH deposit]"
              << " depositor=" << bytes_to_hex(std::vector<uint8_t>(p.begin(), p.begin() + 20))
              << " value="     << word_to_uint256(abi_word_at(p, 20)) << std::endl;
}

static std::string decode_eth_exec_layer_hex(const std::vector<uint8_t> &p) {
    if (p.size() <= 52) return "";
    return bytes_to_hex(std::vector<uint8_t>(p.begin() + 52, p.end()));
}

// ERC20: InputEncoding.encodeERC20Deposit (rollups-contracts v2) —
//   abi.encodePacked(token 20B, sender 20B, value 32B, execLayerData)
static void parse_erc20_deposit(const std::vector<uint8_t> &p) {
    if (p.size() < 72) { std::cerr << "[ERC20 deposit] payload too short\n"; return; }
    std::cout << "[ERC20 deposit]"
              << " token="    << bytes_to_hex(std::vector<uint8_t>(p.begin(), p.begin() + 20))
              << " depositor="<< bytes_to_hex(std::vector<uint8_t>(p.begin() + 20, p.begin() + 40))
              << " amount="   << word_to_uint256(abi_word_at(p, 40)) << std::endl;
}

// execLayerData is concatenated after the 72-byte fixed prefix (no ABI length prefix).
static std::string decode_erc20_exec_layer_hex(const std::vector<uint8_t> &p) {
    if (p.size() <= 72) return "";
    return bytes_to_hex(std::vector<uint8_t>(p.begin() + 72, p.end()));
}

// ERC721: packed header 72B then abi.encode(baseLayerData, execLayerData)
static void parse_erc721_deposit(const std::vector<uint8_t> &p) {
    if (p.size() < 72) { std::cerr << "[ERC721 deposit] payload too short\n"; return; }
    std::cout << "[ERC721 deposit]"
              << " token="   << bytes_to_hex(std::vector<uint8_t>(p.begin(), p.begin() + 20))
              << " sender="  << bytes_to_hex(std::vector<uint8_t>(p.begin() + 20, p.begin() + 40))
              << " tokenId=" << word_to_uint256(abi_word_at(p, 40)) << std::endl;
}

static void erc721_base_exec_hex(const std::vector<uint8_t> &p, std::string &base_hex, std::string &exec_hex) {
    static const size_t k_inner = 72;
    decode_abi_bytes_pair(p, k_inner, base_hex, exec_hex);
}

// ERC1155 single: packed header 104B then abi.encode(baseLayerData, execLayerData)
static void parse_erc1155_single_deposit(const std::vector<uint8_t> &p) {
    if (p.size() < 104) { std::cerr << "[ERC1155 single] payload too short\n"; return; }
    std::cout << "[ERC1155 single deposit]"
              << " token="  << bytes_to_hex(std::vector<uint8_t>(p.begin(), p.begin() + 20))
              << " sender=" << bytes_to_hex(std::vector<uint8_t>(p.begin() + 20, p.begin() + 40))
              << " id="     << word_to_uint256(abi_word_at(p, 40))
              << " amount=" << word_to_uint256(abi_word_at(p, 72)) << std::endl;
}

static void erc1155_single_base_exec_hex(const std::vector<uint8_t> &p, std::string &base_hex, std::string &exec_hex) {
    static const size_t k_inner = 104;
    decode_abi_bytes_pair(p, k_inner, base_hex, exec_hex);
}

// ERC1155 batch: abi.encode(address token, address sender, uint256[] ids, uint256[] amounts, bytes baseLayerData, bytes execLayerData)
static void parse_erc1155_batch_deposit(const std::vector<uint8_t> &p) {
    // Payload format (InputEncoding.sol encodeBatchERC1155Deposit):
    //   abi.encodePacked(token[20B], sender[20B],
    //       abi.encode(tokenIds[], values[], baseLayerData, execLayerData))
    // Addresses are 20-byte packed (NOT 32-byte ABI-padded).
    // ABI sub-encoding starts at byte 40; its offsets are relative to byte 40.
    if (p.size() < 40 + 64) { std::cerr << "[ERC1155 batch] payload too short\n"; return; }
    std::string token  = bytes_to_hex(std::vector<uint8_t>(p.begin(), p.begin() + 20));
    std::string sender = bytes_to_hex(std::vector<uint8_t>(p.begin() + 20, p.begin() + 40));
    const size_t base = 40;  // sub-encoding starts here
    // Offsets in sub-encoding are relative to base
    uint64_t ids_rel  = word_to_uint64(abi_word_at(p, base +  0));
    uint64_t amts_rel = word_to_uint64(abi_word_at(p, base + 32));
    uint64_t ids_off  = base + ids_rel;
    uint64_t amts_off = base + amts_rel;
    uint64_t ids_len  = 0, amts_len = 0;
    if (ids_off  + 32 <= p.size()) ids_len  = word_to_uint64(abi_word_at(p, (size_t)ids_off));
    if (amts_off + 32 <= p.size()) amts_len = word_to_uint64(abi_word_at(p, (size_t)amts_off));
    std::cout << "[ERC1155 batch deposit]"
              << " token=" << token << " sender=" << sender
              << " ids_count=" << ids_len << std::endl;
    for (uint64_t i = 0; i < ids_len; i++) {
        std::string id  = word_to_uint256(abi_word_at(p, (size_t)(ids_off  + 32 + i * 32)));
        std::string amt = (i < amts_len)
            ? word_to_uint256(abi_word_at(p, (size_t)(amts_off + 32 + i * 32))) : "?";
        std::cout << "  [" << i << "] id=" << id << " amount=" << amt << std::endl;
    }
}

// Offsets to baseLayerData / execLayerData (4th and 5th dynamic fields) relative to `base`.
static void erc1155_batch_base_exec_hex(const std::vector<uint8_t> &p, size_t base, std::string &base_hex, std::string &exec_hex) {
    base_hex = "";
    exec_hex = "";
    if (p.size() < base + 128) return;
    uint64_t rel_b = word_to_uint64(abi_word_at(p, base + 64));
    uint64_t rel_e = word_to_uint64(abi_word_at(p, base + 96));
    if (base + rel_b + 32 > p.size() || base + rel_e + 32 > p.size()) return;
    std::vector<uint8_t> vb = abi_read_bytes_vector(p, base + rel_b);
    std::vector<uint8_t> ve = abi_read_bytes_vector(p, base + rel_e);
    if (!vb.empty()) base_hex = bytes_to_hex(vb);
    if (!ve.empty()) exec_hex = bytes_to_hex(ve);
}

// =============================================================================
// PAYLOAD HELPERS
// =============================================================================

// Generate a test payload of exactly `size` bytes (repeating pattern i & 0xff)
static std::vector<uint8_t> make_payload(size_t size_bytes) {
    std::vector<uint8_t> data(size_bytes);
    for (size_t i = 0; i < size_bytes; i++)
        data[i] = (uint8_t)(i & 0xff);
    return data;
}

// =============================================================================
// QA HELPERS (raw outputs, forged yields, argument parsing)
// =============================================================================

// Largest size the generators accept. Anything above can never fit the 2 MiB
// CMIO buffer; the cap only keeps a typo from exhausting guest RAM.
static const size_t MAX_GENERATED_SIZE = 32u << 20;

static size_t size_arg(const picojson::value &in, const char *key, double dflt) {
    double v = in.contains(key) ? in.get(key).get<double>() : dflt;
    if (v < 0 || v > (double)MAX_GENERATED_SIZE)
        throw std::runtime_error(std::string(key) + " out of range");
    return (size_t)v;
}

static std::string str_arg(const picojson::value &in, const char *key, const std::string &dflt) {
    return in.contains(key) ? in.get(key).get<std::string>() : dflt;
}

// Strict hex decoding ("0x" optional, even length, hex digits only).
static bool parse_hex_strict(const std::string &hex, std::vector<uint8_t> &out) {
    std::string h = hex;
    if (h.size() >= 2 && h[0] == '0' && (h[1] == 'x' || h[1] == 'X')) h = h.substr(2);
    if (h.size() % 2 != 0) return false;
    for (char c : h)
        if (!isxdigit((unsigned char)c)) return false;
    out = hex_to_bytes(h);
    return true;
}

// Report that explains why a QA command failed (reports survive a rejected
// input), then reject.
static std::string fail(const std::string &what) {
    std::string msg = what;
    if (g_last_rc) msg += " rc=" + std::to_string(g_last_rc) + " (" + strerror(-g_last_rc) + ")";
    std::cerr << "[qa] " << msg << std::endl;
    emit_report(str_bytes(msg));
    return "reject";
}

// Raw output ("blob"): exactly these bytes, not ABI-wrapped, become one output
// (an outputs-merkle-tree leaf). Same yield and merkle bookkeeping as
// cmt_rollup_emit_notice, minus the Notice encoding.
static bool emit_blob(const std::vector<uint8_t> &data) {
    cmt_buf_t tx = cmt_io_get_tx(g_rollup.io);
    if (data.size() > cmt_buf_length(&tx)) return check_rc("blob", -ENOBUFS);
    if (!data.empty()) memcpy(tx.begin, data.data(), data.size());
    struct cmt_io_yield req;
    req.dev = HTIF_DEVICE_YIELD;
    req.cmd = HTIF_YIELD_CMD_AUTOMATIC;
    req.reason = HTIF_YIELD_AUTOMATIC_REASON_TX_OUTPUT;
    req.data = (uint32_t)data.size();
    int rc = cmt_io_yield(g_rollup.io, &req);
    if (rc) return check_rc("blob", rc);
    return check_rc("blob", cmt_merkle_push_back_data(g_rollup.merkle, data.size(), tx.begin));
}

// A request delivered by a hand-made "accepted" yield (see yield_forged_root);
// main() processes it instead of calling cmt_rollup_finish.
static bool g_pending_request = false;
static int g_pending_request_type = 0;

// Finish the current advance as accepted but declare `len` bytes of 0x5a as
// the outputs merkle root instead of the real one. len 32: the node accepts
// the input and marks the app INVALID_OUTPUTS_ROOT when the epoch closes;
// len != 32: the input itself fails as INVALID_OUTPUTS_ROOT.
static std::string yield_forged_root(uint32_t len) {
    cmt_buf_t tx = cmt_io_get_tx(g_rollup.io);
    memset(tx.begin, 0x5a, len);
    struct cmt_io_yield req;
    req.dev = HTIF_DEVICE_YIELD;
    req.cmd = HTIF_YIELD_CMD_MANUAL;
    req.reason = HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED;
    req.data = len;
    std::cout << "[qa] accepted yield with a forged " << len << "-byte outputs root" << std::endl;
    int rc = cmt_io_yield(g_rollup.io, &req);
    if (rc) {
        std::cerr << "[qa] forged-root yield failed rc=" << rc << "\n";
        return "halt";
    }
    // Same bookkeeping as cmt_rollup_finish after an accepted yield.
    g_rollup.fromhost_data = req.data;
    g_pending_request = true;
    g_pending_request_type = req.reason;
    return "pending";
}

// Manual yield with a reason the node does not know (UNEXPECTED_YIELD).
static std::string yield_unexpected() {
    struct cmt_io_yield req;
    req.dev = HTIF_DEVICE_YIELD;
    req.cmd = HTIF_YIELD_CMD_MANUAL;
    req.reason = 9;
    req.data = 23;
    std::cout << "[qa] manual yield with unexpected reason 9" << std::endl;
    (void)cmt_io_yield(g_rollup.io, &req);
    return "halt"; // never resumed by the node; exit if it ever is
}

// force_exception payload: "hex" (raw bytes) wins over "message" (text).
static bool exception_payload(const picojson::value &in, std::vector<uint8_t> &out) {
    if (in.contains("hex")) return parse_hex_strict(in.get("hex").get<std::string>(), out);
    out = str_bytes(str_arg(in, "message", "test_exception"));
    return true;
}

// emit_blob bytes: "hex" (exact bytes) or "size" bytes of pattern i & 0xff
// with an optional "prefix" written over the first bytes.
static bool blob_bytes(const picojson::value &in, std::vector<uint8_t> &out, std::string &err) {
    if (in.contains("hex")) {
        if (!parse_hex_strict(in.get("hex").get<std::string>(), out)) { err = "invalid hex"; return false; }
        return true;
    }
    out = make_payload(size_arg(in, "size", 0));
    if (in.contains("prefix")) {
        std::vector<uint8_t> p;
        if (!parse_hex_strict(in.get("prefix").get<std::string>(), p)) { err = "invalid prefix"; return false; }
        if (p.size() > out.size()) { err = "prefix longer than size"; return false; }
        std::copy(p.begin(), p.end(), out.begin());
    }
    return true;
}

static const int MAX_SEQ_DEPTH = 4;

// =============================================================================
// ADVANCE HANDLER
// =============================================================================
// Handlers return the request outcome: "accept", "reject", "exception" (an
// exception yield was issued), "halt" (exit the process: the machine halts) or
// "pending" (a forged accepted yield already fetched the next request).
static std::string run_advance(const picojson::value &input, int depth);
static std::string run_inspect(const picojson::value &input, const std::vector<uint8_t> &payload, int depth);

static std::string handle_advance(const cmt_rollup_advance_t &adv) {
    std::string msg_sender = to_lower(bytes_to_hex(std::vector<uint8_t>(
        adv.msg_sender.data, adv.msg_sender.data + CMT_ABI_ADDRESS_LENGTH)));
    const uint8_t *pl = (const uint8_t *)adv.payload.data;
    std::vector<uint8_t> raw(pl, pl + adv.payload.length);

    // Record the app's own address the first time we see it
    if (g_app_address.empty()) {
        g_app_address = to_lower(bytes_to_hex(std::vector<uint8_t>(
            adv.app_contract.data, adv.app_contract.data + CMT_ABI_ADDRESS_LENGTH)));
        std::cout << "[advance] app_address=" << g_app_address << std::endl;
    }

    std::cout << "[advance] index=" << adv.index << " msg_sender=" << msg_sender << std::endl;

    // ── Detect deposits by msg_sender matching a portal address ───────────
    if (msg_sender == ADDR_ETH_PORTAL) {
        parse_eth_deposit(raw);
        std::string ack = "ETH OK";
        std::string exec_h = decode_eth_exec_layer_hex(raw);
        if (!exec_h.empty()) {
            ack += " exec=";
            ack += exec_h;
        }
        emit_notice(str_bytes(ack));
        return "accept";
    }
    if (msg_sender == ADDR_ERC20_PORTAL) {
        parse_erc20_deposit(raw);
        std::string exec_hex = decode_erc20_exec_layer_hex(raw);
        std::string ack = "ERC20 OK";
        if (!exec_hex.empty()) {
            ack += " exec=";
            ack += exec_hex;
        }
        emit_notice(str_bytes(ack));
        return "accept";
    }
    if (msg_sender == ADDR_ERC721_PORTAL) {
        parse_erc721_deposit(raw);
        std::string ack = "ERC721 OK";
        std::string bhx, ehx;
        erc721_base_exec_hex(raw, bhx, ehx);
        if (!bhx.empty()) {
            ack += " base=";
            ack += bhx;
        }
        if (!ehx.empty()) {
            ack += " exec=";
            ack += ehx;
        }
        emit_notice(str_bytes(ack));
        return "accept";
    }
    if (msg_sender == ADDR_ERC1155_SINGLE_PORTAL) {
        parse_erc1155_single_deposit(raw);
        std::string ack = "1155S OK";
        std::string bhx, ehx;
        erc1155_single_base_exec_hex(raw, bhx, ehx);
        if (!bhx.empty()) {
            ack += " base=";
            ack += bhx;
        }
        if (!ehx.empty()) {
            ack += " exec=";
            ack += ehx;
        }
        emit_notice(str_bytes(ack));
        return "accept";
    }
    if (msg_sender == ADDR_ERC1155_BATCH_PORTAL) {
        parse_erc1155_batch_deposit(raw);
        std::string ack = "1155B OK";
        const size_t base = 40;
        std::string bhx, ehx;
        if (raw.size() >= base + 128)
            erc1155_batch_base_exec_hex(raw, base, bhx, ehx);
        if (!bhx.empty()) {
            ack += " base=";
            ack += bhx;
        }
        if (!ehx.empty()) {
            ack += " exec=";
            ack += ehx;
        }
        emit_notice(str_bytes(ack));
        return "accept";
    }

    // ── Regular JSON input ─────────────────────────────────────────────────
    std::string json_str(raw.begin(), raw.end());
    picojson::value input;
    std::string parse_err = picojson::parse(input, json_str);
    if (!parse_err.empty() || !input.is<picojson::object>()) {
        std::cerr << "[advance] cannot parse JSON payload: " << parse_err << std::endl;
        return "reject";
    }

    if (!input.contains("cmd")) {
        std::cerr << "[advance] missing 'cmd' field in JSON\n";
        return "reject";
    }

    return run_advance(input, 0);
}

static std::string run_advance(const picojson::value &input, int depth) {
    std::string cmd = input.get("cmd").get<std::string>();
    std::cout << "[advance] cmd=" << cmd << std::endl;

    // set_mint_contract ──────────────────────────────────────────────────────
    if (cmd == "set_mint_contract") {
        g_mint_contract = to_lower(input.get("address").get<std::string>());
        std::cout << "[advance] mint_contract=" << g_mint_contract << std::endl;
        emit_notice(str_bytes("mint_contract=" + g_mint_contract));
        return "accept";
    }

    // generate_notices ───────────────────────────────────────────────────────
    if (cmd == "generate_notices") {
        size_t sz    = (size_t)input.get("size").get<double>();
        size_t count = (size_t)input.get("count").get<double>();
        std::vector<uint8_t> payload = make_payload(sz);
        std::cout << "[advance] generating " << count
                  << " notices of " << sz << " bytes" << std::endl;
        for (size_t i = 0; i < count; i++) {
            if (!emit_notice(payload)) {
                std::cerr << "[advance] notice " << i << " rejected (too large?)\n";
                return "reject";
            }
        }
        return "accept";
    }

    // force_exception — exception yield; input completes as EXCEPTION.
    // Payload: "message" (text, default "test_exception") or "hex" (raw bytes).
    if (cmd == "force_exception") {
        std::vector<uint8_t> mb;
        if (!exception_payload(input, mb)) return fail("force_exception: invalid hex");
        std::cout << "[advance] raising exception payload len=" << mb.size() << std::endl;
        if (!emit_exception(mb)) return "reject";
        return "exception";
    }

    // advance_reports — emit reports during an advance (same limits as notices)
    if (cmd == "advance_reports") {
        size_t sz    = (size_t)input.get("size").get<double>();
        size_t count = (size_t)input.get("count").get<double>();
        std::vector<uint8_t> payload = make_payload(sz);
        for (size_t i = 0; i < count; i++) {
            if (!emit_report(payload)) {
                std::cerr << "[advance] report " << i << " rejected\n";
                return "reject";
            }
        }
        return "accept";
    }

    // mixed_outputs — one notice + one report + one ERC-20 voucher in a single advance
    if (cmd == "mixed_outputs") {
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        std::string ntxt     = input.contains("noticeText")
            ? input.get("noticeText").get<std::string>()
            : std::string("MIXED_OK");
        emit_notice(str_bytes(ntxt));
        std::string rtxt = input.contains("reportText")
            ? input.get("reportText").get<std::string>()
            : std::string("mixed_report");
        emit_report(str_bytes(rtxt));
        (void)emit_voucher(token, build_erc20_transfer(receiver, amount));
        std::cout << "[advance] mixed_outputs notice+report+voucher\n";
        return "accept";
    }

    // multi_erc20_withdraw — two ERC-20 vouchers in one advance (execution order on L1)
    if (cmd == "multi_erc20_withdraw") {
        std::string token     = input.get("token").get<std::string>();
        std::string receiver  = input.get("receiver").get<std::string>();
        std::string amount_a  = input.get("amountFirst").get<std::string>();
        std::string amount_b  = input.get("amountSecond").get<std::string>();
        (void)emit_voucher(token, build_erc20_transfer(receiver, amount_a));
        (void)emit_voucher(token, build_erc20_transfer(receiver, amount_b));
        std::cout << "[advance] multi_erc20_withdraw two vouchers\n";
        return "accept";
    }

    // large_voucher — single voucher with near–2 MB calldata (rollup output size limit)
    if (cmd == "large_voucher") {
        std::string dest = input.get("destination").get<std::string>();
        size_t sz        = (size_t)input.get("payloadBytes").get<double>();
        if (sz > 2100000) {
            std::cerr << "[advance] large_voucher payload too large\n";
            return "reject";
        }
        if (!emit_voucher(dest, make_payload(sz))) return "reject";
        std::cout << "[advance] large_voucher bytes=" << sz << std::endl;
        return "accept";
    }

    // eth_withdraw ───────────────────────────────────────────────────────────
    // v2: destination=receiver, payload=0x (empty), value=amount
    if (cmd == "eth_withdraw") {
        std::string receiver = input.get("receiver").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        (void)emit_voucher(receiver, std::vector<uint8_t>(), amount);
        std::cout << "[advance] voucher: eth_withdraw to=" << receiver
                  << " value=" << amount << std::endl;
        return "accept";
    }

    // erc20_withdraw — optional valueField: "omit" (default) vs "zero_hash" (32-byte zero value).
    // Both encode value 0 in the Voucher output.
    if (cmd == "erc20_withdraw") {
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        auto calldata = build_erc20_transfer(receiver, amount);
        std::string vf = "omit";
        if (input.contains("valueField")) vf = input.get("valueField").get<std::string>();
        if (vf == "zero_hash") {
            (void)emit_voucher(token, calldata, "0x" + std::string(64, '0'));
        } else {
            (void)emit_voucher(token, calldata);
        }
        std::cout << "[advance] voucher: erc20_withdraw token=" << token
                  << " to=" << receiver << " valueField=" << vf << std::endl;
        return "accept";
    }

    // delegate_erc20_transfer — DELEGATECALL voucher via DelegateVoucherLogic
    if (cmd == "delegate_erc20_transfer") {
        std::string logic    = input.get("logic").get<std::string>();
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        auto calldata = build_delegate_erc20_transfer(token, receiver, amount);
        (void)emit_delegate_voucher(logic, calldata);
        std::cout << "[advance] delegate-call-voucher: transferERC20 logic=" << logic
                  << " token=" << token << " to=" << receiver << std::endl;
        return "accept";
    }

    // delegate_erc20_transfer_targeted — only `allowedExecutor` may execute on L1
    if (cmd == "delegate_erc20_transfer_targeted") {
        std::string logic    = input.get("logic").get<std::string>();
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        std::string allowed  = input.get("allowedExecutor").get<std::string>();
        auto calldata = build_delegate_erc20_targeted(token, receiver, amount, allowed);
        (void)emit_delegate_voucher(logic, calldata);
        std::cout << "[advance] delegate-call-voucher: transferERC20Targeted logic=" << logic
                  << " allowedExecutor=" << allowed << std::endl;
        return "accept";
    }

    // erc721_withdraw ────────────────────────────────────────────────────────
    if (cmd == "erc721_withdraw") {
        if (g_app_address.empty()) {
            std::cerr << "[advance] app_address unknown; send at least one advance first\n";
            return "reject";
        }
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string token_id = input.get("tokenId").get<std::string>();
        auto calldata = build_erc721_safe_transfer(g_app_address, receiver, token_id);
        (void)emit_voucher(token, calldata);
        std::cout << "[advance] voucher: erc721_withdraw to=" << receiver
                  << " tokenId=" << token_id << std::endl;
        return "accept";
    }

    // erc1155_withdraw_single ────────────────────────────────────────────────
    if (cmd == "erc1155_withdraw_single") {
        if (g_app_address.empty()) { std::cerr << "[advance] app_address unknown\n"; return "reject"; }
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        std::string id       = input.get("id").get<std::string>();
        std::string amount   = input.get("amount").get<std::string>();
        auto calldata = build_erc1155_safe_transfer(g_app_address, receiver, id, amount);
        (void)emit_voucher(token, calldata);
        std::cout << "[advance] voucher: erc1155_withdraw_single to=" << receiver << std::endl;
        return "accept";
    }

    // erc1155_withdraw_batch ─────────────────────────────────────────────────
    if (cmd == "erc1155_withdraw_batch") {
        if (g_app_address.empty()) { std::cerr << "[advance] app_address unknown\n"; return "reject"; }
        std::string token    = input.get("token").get<std::string>();
        std::string receiver = input.get("receiver").get<std::string>();
        picojson::array ids_arr    = input.get("ids").get<picojson::array>();
        picojson::array amounts_arr= input.get("amounts").get<picojson::array>();
        std::vector<std::string> ids, amounts;
        for (auto &v : ids_arr)     ids.push_back(v.get<std::string>());
        for (auto &v : amounts_arr) amounts.push_back(v.get<std::string>());
        auto calldata = build_erc1155_safe_batch(g_app_address, receiver, ids, amounts);
        (void)emit_voucher(token, calldata);
        std::cout << "[advance] voucher: erc1155_withdraw_batch ids=" << ids.size()
                  << " to=" << receiver << std::endl;
        return "accept";
    }

    // mint_erc721 ────────────────────────────────────────────────────────────
    if (cmd == "mint_erc721") {
        if (g_mint_contract.empty()) {
            std::cerr << "[advance] mint_contract not set; send set_mint_contract first\n";
            return "reject";
        }
        std::string receiver = input.get("receiver").get<std::string>();
        std::string token_id = input.get("tokenId").get<std::string>();
        auto calldata = build_erc721_mint(receiver, token_id);
        (void)emit_voucher(g_mint_contract, calldata);
        std::cout << "[advance] voucher: mint_erc721 to=" << receiver
                  << " tokenId=" << token_id << std::endl;
        return "accept";
    }

    // ── QA commands ─────────────────────────────────────────────────────────

    // emit_blob — raw output(s) of exact bytes ("hex") or "size" pattern bytes
    if (cmd == "emit_blob") {
        std::vector<uint8_t> blob;
        std::string err;
        size_t count = size_arg(input, "count", 1);
        g_last_rc = 0;
        if (!blob_bytes(input, blob, err)) return fail("emit_blob: " + err);
        for (size_t i = 0; i < count; i++)
            if (!emit_blob(blob))
                return fail("emit_blob failed: size=" + std::to_string(blob.size()) + " i=" + std::to_string(i));
        std::cout << "[advance] emit_blob " << count << " x " << blob.size() << " bytes" << std::endl;
        return "accept";
    }

    // emit_reports / emit_notices — N outputs of "size" bytes (pattern i & 0xff)
    if (cmd == "emit_reports" || cmd == "emit_notices") {
        bool reports = cmd == "emit_reports";
        size_t count = size_arg(input, "count", 1);
        std::vector<uint8_t> p = make_payload(size_arg(input, "size", 16));
        for (size_t i = 0; i < count; i++) {
            bool ok = reports ? emit_report(p) : emit_notice(p);
            if (!ok)
                return fail(cmd + " failed: size=" + std::to_string(p.size()) + " i=" + std::to_string(i));
        }
        std::cout << "[advance] " << cmd << " " << count << " x " << p.size() << " bytes" << std::endl;
        return "accept";
    }

    // emit_notice_exact — one notice whose payload is exactly "size" bytes,
    // plus a report with the payload and encoded sizes (or why it failed)
    if (cmd == "emit_notice_exact") {
        size_t sz = size_arg(input, "size", 0);
        size_t encoded = 4 + 32 + 32 + (sz + 31) / 32 * 32;
        std::string info = "emit_notice_exact payload=" + std::to_string(sz) +
                           " encoded=" + std::to_string(encoded);
        if (!emit_notice(make_payload(sz))) return fail(info + " failed");
        emit_report(str_bytes(info + " ok"));
        return "accept";
    }

    // voucher / delegate_voucher — arbitrary destination and calldata
    if (cmd == "voucher" || cmd == "delegate_voucher") {
        std::string dest = input.get("destination").get<std::string>();
        std::vector<uint8_t> payload;
        g_last_rc = 0;
        if (!parse_hex_strict(str_arg(input, "payload", "0x"), payload))
            return fail(cmd + ": invalid payload hex");
        bool ok = cmd == "voucher" ? emit_voucher(dest, payload, str_arg(input, "value", ""))
                                   : emit_delegate_voucher(dest, payload);
        if (!ok) return fail(cmd + " failed: destination=" + dest);
        return "accept";
    }

    // reject — finish the input as REJECTED (outputs of this input are discarded,
    // reports are kept)
    if (cmd == "reject") {
        std::cout << "[advance] rejecting on request" << std::endl;
        return "reject";
    }

    // halt — the dapp process exits; the machine halts (MACHINE_HALTED, terminal)
    if (cmd == "halt") {
        std::cout << "[advance] halting on request" << std::endl;
        return "halt";
    }

    // unexpected_yield / invalid_outputs_root / invalid_outputs_root_length —
    // the other guest-caused terminal outcomes
    if (cmd == "unexpected_yield") return yield_unexpected();
    if (cmd == "invalid_outputs_root") return yield_forged_root(32);
    if (cmd == "invalid_outputs_root_length") return yield_forged_root(31);

    // seq — run "steps" (command objects) in order; stops at the first step that
    // does not accept and returns its outcome
    if (cmd == "seq") {
        if (depth >= MAX_SEQ_DEPTH) throw std::runtime_error("seq nested too deep");
        const picojson::array &steps = input.get("steps").get<picojson::array>();
        for (size_t i = 0; i < steps.size(); i++) {
            std::string st = run_advance(steps[i], depth + 1);
            if (st != "accept") return st;
        }
        return "accept";
    }

    std::cerr << "[advance] unknown cmd: " << cmd << std::endl;
    return "reject";
}

// =============================================================================
// INSPECT HANDLER
// =============================================================================
static std::string handle_inspect(const cmt_rollup_inspect_t &ins) {
    const uint8_t *pl = (const uint8_t *)ins.payload.data;
    std::vector<uint8_t> payload(pl, pl + ins.payload.length);
    std::string json_str(payload.begin(), payload.end());
    std::cout << "[inspect] raw payload: " << json_str.substr(0, 256) << std::endl;

    // Clients may wrap the JSON command in {"payload":"0x<hex>"}; unwrap it so
    // the dapp sees the actual JSON command the client sent.
    {
        picojson::value outer;
        std::string outer_err = picojson::parse(outer, json_str);
        if (outer_err.empty() && outer.is<picojson::object>() &&
            outer.contains("payload") && !outer.contains("cmd") &&
            outer.get("payload").is<std::string>()) {
            payload  = hex_to_bytes(outer.get("payload").get<std::string>());
            json_str = std::string(payload.begin(), payload.end());
            std::cout << "[inspect] unwrapped envelope, inner payload: " << json_str.substr(0, 256) << std::endl;
        }
    }

    picojson::value input;
    std::string parse_err = picojson::parse(input, json_str);
    if (!parse_err.empty()) {
        std::cerr << "[inspect] parse error: " << parse_err << std::endl;
        std::cout << "[inspect] echoing payload due to parse error\n";
        emit_report(payload);
        return "accept";
    }
    if (!input.is<picojson::object>()) {
        std::cerr << "[inspect] input is not an object\n";
        std::cout << "[inspect] echoing payload (not object)\n";
        emit_report(payload);
        return "accept";
    }

    if (!input.contains("cmd")) {
        std::cerr << "[inspect] missing 'cmd' field\n";
        emit_report(payload);
        return "accept";
    }

    return run_inspect(input, payload, 0);
}

static std::string run_inspect(const picojson::value &input, const std::vector<uint8_t> &payload, int depth) {
    std::string cmd = input.get("cmd").get<std::string>();
    std::cout << "[inspect] cmd=" << cmd << std::endl;

    // generate_reports ───────────────────────────────────────────────────────
    if (cmd == "generate_reports") {
        if (!input.contains("size") || !input.contains("count")) {
            std::cerr << "[inspect] missing 'size' or 'count' fields\n";
            return "accept";
        }
        size_t sz    = (size_t)input.get("size").get<double>();
        size_t count = (size_t)input.get("count").get<double>();
        std::vector<uint8_t> rp = make_payload(sz);
        std::cout << "[inspect] generating " << count
                  << " reports of " << sz << " bytes each" << std::endl;
        for (size_t i = 0; i < count; i++) {
            if (!emit_report(rp)) {
                std::cerr << "[inspect] report " << i << " rejected (too large?)\n";
                return "accept"; // inspect always returns accept, but no more reports
            }
        }
        std::cout << "[inspect] done emitting " << count << " reports\n";
        return "accept";
    }

    // echo ───────────────────────────────────────────────────────────────────
    if (cmd == "echo") {
        emit_report(payload);
        return "accept";
    }

    // emit_reports — N reports of "size" bytes (pattern i & 0xff)
    if (cmd == "emit_reports") {
        size_t count = size_arg(input, "count", 1);
        std::vector<uint8_t> rp = make_payload(size_arg(input, "size", 16));
        for (size_t i = 0; i < count; i++)
            if (!emit_report(rp)) break; // inspect: no more reports, still accepted
        return "accept";
    }

    // reject — inspect status "Rejected"
    if (cmd == "reject") return "reject";

    // force_exception — inspect status "Exception", exception_data = payload
    if (cmd == "force_exception") {
        std::vector<uint8_t> payload;
        if (!exception_payload(input, payload)) {
            emit_report(str_bytes("force_exception: invalid hex"));
            return "accept";
        }
        emit_exception(payload);
        return "exception";
    }

    // halt — the process exits during the inspect: status "MachineHalted"
    // (only the inspect's temporary machine halts; the app stays OK)
    if (cmd == "halt") return "halt";

    // unexpected_yield — inspect status "Failed"
    if (cmd == "unexpected_yield") return yield_unexpected();

    // seq — same as on advance, with the inspect commands
    if (cmd == "seq") {
        if (depth >= MAX_SEQ_DEPTH) throw std::runtime_error("seq nested too deep");
        const picojson::array &steps = input.get("steps").get<picojson::array>();
        for (size_t i = 0; i < steps.size(); i++) {
            std::string st = run_inspect(steps[i], payload, depth + 1);
            if (st != "accept") return st;
        }
        return "accept";
    }

    emit_report(str_bytes("unknown inspect cmd: " + cmd));
    return "accept";
}

// =============================================================================
// MAIN
// =============================================================================
int main() {
    int rc = cmt_rollup_init(&g_rollup);
    if (rc) {
        std::cerr << "[main] cmt_rollup_init failed rc=" << rc << " (" << strerror(-rc) << ")\n";
        return 1;
    }

    cmt_rollup_finish_t finish;
    memset(&finish, 0, sizeof(finish));
    std::string status = "accept";
    for (;;) {
        if (status == "halt") {
            std::cout << "[main] exiting: the machine halts" << std::endl;
            return 0;
        }
        if (status == "pending") {
            // the next request was already fetched by a forged accepted yield
            g_pending_request = false;
            finish.next_request_type = g_pending_request_type;
        } else {
            std::cout << "[main] finish status=" << status << std::endl;
            finish.accept_previous_request = (status == "accept" || status == "exception");
            rc = cmt_rollup_finish(&g_rollup, &finish);
            if (rc) {
                std::cerr << "[main] cmt_rollup_finish failed rc=" << rc << " (" << strerror(-rc) << ")\n";
                return 1;
            }
        }
        try {
            if (finish.next_request_type == HTIF_YIELD_REASON_ADVANCE_STATE) {
                cmt_rollup_advance_t adv;
                rc = cmt_rollup_read_advance_state(&g_rollup, &adv);
                if (rc) {
                    std::cerr << "[main] cannot read advance state rc=" << rc << "\n";
                    status = "reject";
                    continue;
                }
                status = handle_advance(adv);
            } else if (finish.next_request_type == HTIF_YIELD_REASON_INSPECT_STATE) {
                cmt_rollup_inspect_t ins;
                rc = cmt_rollup_read_inspect_state(&g_rollup, &ins);
                if (rc) {
                    std::cerr << "[main] cannot read inspect state rc=" << rc << "\n";
                    status = "reject";
                    continue;
                }
                status = handle_inspect(ins);
            } else {
                std::cerr << "[main] unknown request type " << finish.next_request_type << "\n";
                status = "reject";
            }
        } catch (const std::exception &e) {
            std::cerr << "[main] exception: " << e.what() << "\n";
            status = "reject";
        }
    }
    return 0;
}
