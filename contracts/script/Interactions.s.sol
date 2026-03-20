// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20}   from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}  from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

// ── Minimal Cartesi v2 portal interfaces ─────────────────────────────────────

interface IEtherPortal {
    function depositEther(
        address appContract,
        bytes calldata execLayerData
    ) external payable;
}

interface IERC20Portal {
    function depositERC20Tokens(
        IERC20 token,
        address appContract,
        uint256 amount,
        bytes calldata execLayerData
    ) external;
}

interface IERC721Portal {
    function depositERC721Token(
        IERC721 token,
        address appContract,
        uint256 tokenId,
        bytes calldata baseLayerData,
        bytes calldata execLayerData
    ) external;
}

interface IERC1155SinglePortal {
    function depositSingleERC1155Token(
        IERC1155 token,
        address appContract,
        uint256 id,
        uint256 amount,
        bytes calldata baseLayerData,
        bytes calldata execLayerData
    ) external;
}

interface IERC1155BatchPortal {
    function depositBatchERC1155Token(
        IERC1155 token,
        address appContract,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata baseLayerData,
        bytes calldata execLayerData
    ) external;
}

interface IInputBox {
    function addInput(address appContract, bytes calldata payload)
        external returns (bytes32);
}

// ─────────────────────────────────────────────────────────────────────────────

/// @notice Sends all interaction types to a running Cartesi devnet.
///
/// Required env vars  (all pre-filled from `cartesi address-book` + `cartesi run` output):
///   PRIVATE_KEY              — Anvil default key (see README)
///   CARTESI_APP_ADDRESS      — shown by `cartesi run`
///   INPUT_BOX_ADDRESS        — 0x1b51e2992A2755Ba4D6F7094032DF91991a0Cfac
///   ETH_PORTAL_ADDRESS       — 0xA632c5c05812c6a6149B7af5C56117d1D2603828
///   ERC20_PORTAL_ADDRESS     — 0xACA6586A0Cf05bD831f2501E7B4aea550dA6562D
///   ERC721_PORTAL_ADDRESS    — 0x9E8851dadb2b77103928518846c4678d48b5e371
///   ERC1155_SINGLE_PORTAL    — 0x18558398Dd1a8cE20956287a4Da7B76aE7A96662
///   ERC1155_BATCH_PORTAL     — 0xe246Abb974B307490d9C6932F48EbE79de72338A
///   TEST_ERC20_ADDRESS       — 0x5138f529B77B4e0a7c84B77E79c4335D31938fed  (pre-deployed TestToken)
///   TEST_ERC721_ADDRESS      — address of deployed TestERC721
///   TEST_ERC1155_ADDRESS     — address of deployed TestERC1155
///
/// Usage (run individual functions via --sig):
///   forge script script/Interactions.s.sol --sig "depositEth()" ...
///   forge script script/Interactions.s.sol --sig "depositERC20()" ...
///   forge script script/Interactions.s.sol --sig "depositERC721()" ...
///   forge script script/Interactions.s.sol --sig "depositERC1155Single()" ...
///   forge script script/Interactions.s.sol --sig "depositERC1155Batch()" ...
///   forge script script/Interactions.s.sol --sig "sendSetMintContract(address)" <addr> ...
///   forge script script/Interactions.s.sol --sig "sendGenerateNotices(uint256,uint256)" 1024 3 ...
///   forge script script/Interactions.s.sol --sig "sendGenerateReports(uint256,uint256)" 1024 2 ...
///   forge script script/Interactions.s.sol --sig "sendEthWithdraw(address,uint256)" <recv> 1e17 ...
///   forge script script/Interactions.s.sol --sig "sendERC20Withdraw(address,address,uint256)" ...
///   forge script script/Interactions.s.sol --sig "sendERC721Withdraw(address,address,uint256)" ...
///   forge script script/Interactions.s.sol --sig "sendERC1155WithdrawSingle(...)"
///   forge script script/Interactions.s.sol --sig "sendERC1155WithdrawBatch(...)"
///   forge script script/Interactions.s.sol --sig "sendMintERC721(address,uint256)" <recv> 100 ...
contract Interactions is Script {

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _key()   internal view returns (uint256) { return vm.envUint("PRIVATE_KEY"); }
    function _app()   internal view returns (address)  { return vm.envAddress("CARTESI_APP_ADDRESS"); }
    function _box()   internal view returns (IInputBox) {
        return IInputBox(vm.envAddress("INPUT_BOX_ADDRESS"));
    }

    /// @dev Encode a JSON advance input as raw bytes (dapp reads hex-decoded JSON)
    function _inputBytes(string memory json) internal pure returns (bytes memory) {
        return bytes(json);
    }

    function _sendInput(string memory json) internal {
        _box().addInput(_app(), _inputBytes(json));
    }

    // ── ETH deposit ───────────────────────────────────────────────────────────

    /// @notice Deposit 0.1 ETH into the Cartesi application via EtherPortal.
    function depositEth() external {
        vm.startBroadcast(_key());
        IEtherPortal(vm.envAddress("ETH_PORTAL_ADDRESS"))
            .depositEther{value: 0.1 ether}(_app(), "");
        vm.stopBroadcast();
        console.log("ETH deposit sent");
    }

    // ── ERC20 deposit ─────────────────────────────────────────────────────────

    /// @notice Deposit 100 tokens of TestERC20.
    function depositERC20() external {
        address tokenAddr = vm.envAddress("TEST_ERC20_ADDRESS");
        address portalAddr = vm.envAddress("ERC20_PORTAL_ADDRESS");
        uint256 amount = 100 ether; // 100 tokens (18 decimals)

        vm.startBroadcast(_key());
        IERC20(tokenAddr).approve(portalAddr, amount);
        IERC20Portal(portalAddr).depositERC20Tokens(
            IERC20(tokenAddr), _app(), amount, ""
        );
        vm.stopBroadcast();
        console.log("ERC20 deposit sent, amount:", amount);
    }

    // ── ERC721 deposit ────────────────────────────────────────────────────────

    /// @notice Deposit token ID 1 from TestERC721.
    function depositERC721() external {
        address tokenAddr  = vm.envAddress("TEST_ERC721_ADDRESS");
        address portalAddr = vm.envAddress("ERC721_PORTAL_ADDRESS");
        uint256 tokenId = 1;

        vm.startBroadcast(_key());
        IERC721(tokenAddr).approve(portalAddr, tokenId);
        IERC721Portal(portalAddr).depositERC721Token(
            IERC721(tokenAddr), _app(), tokenId, "", ""
        );
        vm.stopBroadcast();
        console.log("ERC721 deposit sent, tokenId:", tokenId);
    }

    // ── ERC1155 single deposit ────────────────────────────────────────────────

    /// @notice Deposit 50 of TOKEN_A (id=1) from TestERC1155.
    function depositERC1155Single() external {
        address tokenAddr  = vm.envAddress("TEST_ERC1155_ADDRESS");
        address portalAddr = vm.envAddress("ERC1155_SINGLE_PORTAL");
        uint256 id = 1;
        uint256 amount = 50;

        vm.startBroadcast(_key());
        IERC1155(tokenAddr).setApprovalForAll(portalAddr, true);
        IERC1155SinglePortal(portalAddr).depositSingleERC1155Token(
            IERC1155(tokenAddr), _app(), id, amount, "", ""
        );
        vm.stopBroadcast();
        console.log("ERC1155 single deposit sent, id:", id, "amount:", amount);
    }

    // ── ERC1155 batch deposit ─────────────────────────────────────────────────

    /// @notice Deposit TOKEN_A, TOKEN_B, TOKEN_C in a single batch call.
    function depositERC1155Batch() external {
        address tokenAddr  = vm.envAddress("TEST_ERC1155_ADDRESS");
        address portalAddr = vm.envAddress("ERC1155_BATCH_PORTAL");

        uint256[] memory ids     = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        ids[0] = 1; amounts[0] = 10;  // TOKEN_A
        ids[1] = 2; amounts[1] = 20;  // TOKEN_B
        ids[2] = 3; amounts[2] = 30;  // TOKEN_C

        vm.startBroadcast(_key());
        IERC1155(tokenAddr).setApprovalForAll(portalAddr, true);
        IERC1155BatchPortal(portalAddr).depositBatchERC1155Token(
            IERC1155(tokenAddr), _app(), ids, amounts, "", ""
        );
        vm.stopBroadcast();
        console.log("ERC1155 batch deposit sent, 3 token types");
    }

    // ── Advance: set_mint_contract ────────────────────────────────────────────

    /// @notice Register the MintableERC721 address inside the dapp.
    function sendSetMintContract(address mintContract) external {
        vm.startBroadcast(_key());
        // JSON is sent as raw bytes; dapp decodes hex payload → string → JSON
        string memory json = string(abi.encodePacked(
            '{"cmd":"set_mint_contract","address":"',
            _addrToStr(mintContract),
            '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("set_mint_contract sent for:", mintContract);
    }

    // ── Advance: generate_notices ─────────────────────────────────────────────

    /// @notice Ask the dapp to generate `count` notices of `sizeBytes` each.
    function sendGenerateNotices(uint256 sizeBytes, uint256 count) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"generate_notices","size":', _uint2str(sizeBytes),
            ',"count":', _uint2str(count), '}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("generate_notices sent: size=", sizeBytes, "count=", count);
    }

    // ── Advance: generate_reports (inspect) ───────────────────────────────────

    /// @notice Ask the dapp to generate `count` reports of `sizeBytes` each via inspect.
    ///         This uses addInput so it can be tested as an advance too.
    function sendGenerateReports(uint256 sizeBytes, uint256 count) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"generate_reports","size":', _uint2str(sizeBytes),
            ',"count":', _uint2str(count), '}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("generate_reports sent: size=", sizeBytes, "count=", count);
    }

    // ── Advance: eth_withdraw ─────────────────────────────────────────────────

    function sendEthWithdraw(address receiver, uint256 amount) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"eth_withdraw","receiver":"', _addrToStr(receiver),
            '","amount":"', _uint256ToHex(amount), '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("eth_withdraw input sent");
    }

    // ── Advance: erc20_withdraw ───────────────────────────────────────────────

    function sendERC20Withdraw(address token, address receiver, uint256 amount) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"erc20_withdraw","token":"', _addrToStr(token),
            '","receiver":"', _addrToStr(receiver),
            '","amount":"', _uint256ToHex(amount), '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("erc20_withdraw input sent");
    }

    // ── Advance: erc721_withdraw ──────────────────────────────────────────────

    function sendERC721Withdraw(address token, address receiver, uint256 tokenId) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"erc721_withdraw","token":"', _addrToStr(token),
            '","receiver":"', _addrToStr(receiver),
            '","tokenId":"', _uint256ToHex(tokenId), '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("erc721_withdraw input sent");
    }

    // ── Advance: erc1155_withdraw_single ──────────────────────────────────────

    function sendERC1155WithdrawSingle(
        address token, address receiver,
        uint256 id, uint256 amount
    ) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"erc1155_withdraw_single","token":"', _addrToStr(token),
            '","receiver":"', _addrToStr(receiver),
            '","id":"', _uint256ToHex(id),
            '","amount":"', _uint256ToHex(amount), '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("erc1155_withdraw_single input sent");
    }

    // ── Advance: erc1155_withdraw_batch ───────────────────────────────────────
    // For simplicity this hardcodes a 2-token batch. Extend as needed.

    function sendERC1155WithdrawBatch(
        address token, address receiver,
        uint256 id0, uint256 amount0,
        uint256 id1, uint256 amount1
    ) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"erc1155_withdraw_batch","token":"', _addrToStr(token),
            '","receiver":"', _addrToStr(receiver),
            '","ids":["', _uint256ToHex(id0), '","', _uint256ToHex(id1), '"]',
            ',"amounts":["', _uint256ToHex(amount0), '","', _uint256ToHex(amount1), '"]}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("erc1155_withdraw_batch input sent");
    }

    // ── Advance: mint_erc721 ──────────────────────────────────────────────────

    function sendMintERC721(address receiver, uint256 tokenId) external {
        vm.startBroadcast(_key());
        string memory json = string(abi.encodePacked(
            '{"cmd":"mint_erc721","receiver":"', _addrToStr(receiver),
            '","tokenId":"', _uint256ToHex(tokenId), '"}'
        ));
        _sendInput(json);
        vm.stopBroadcast();
        console.log("mint_erc721 input sent, tokenId:", tokenId);
    }

    // ── String utilities ──────────────────────────────────────────────────────

    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        while (v != 0) {
            buf[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }

    function _addrToStr(address addr) internal pure returns (string memory) {
        bytes memory buf = new bytes(42);
        buf[0] = '0';
        buf[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(uint160(addr) >> (8 * (19 - i)));
            buf[2 + i * 2]     = _HEX_SYMBOLS[(b >> 4) & 0xf];
            buf[2 + i * 2 + 1] = _HEX_SYMBOLS[b & 0xf];
        }
        return string(buf);
    }

    function _uint256ToHex(uint256 v) internal pure returns (string memory) {
        // Returns "0x" + 32-byte big-endian hex (64 hex chars)
        bytes memory buf = new bytes(66);
        buf[0] = '0';
        buf[1] = 'x';
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(v >> (8 * (31 - i)));
            buf[2 + i * 2]     = _HEX_SYMBOLS[(b >> 4) & 0xf];
            buf[2 + i * 2 + 1] = _HEX_SYMBOLS[b & 0xf];
        }
        return string(buf);
    }
}
