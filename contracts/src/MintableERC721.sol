// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice ERC721 where minting is gated by MINTER_ROLE.
///
///         The Cartesi application contract must be granted MINTER_ROLE
///         so that vouchers from the dapp can call mint(address, uint256).
///
///         Typical test setup:
///           1. Deploy MintableERC721 → deployer gets DEFAULT_ADMIN_ROLE
///           2. grantRole(MINTER_ROLE, cartesiAppAddress)
///           3. Send {"cmd":"set_mint_contract","address":"<MintableERC721 address>"}
///              as an advance input to register the address in the dapp.
///           4. Send {"cmd":"mint_erc721","receiver":"0x...","tokenId":"0x..."}
///              to trigger a voucher that calls mint() on this contract.
contract MintableERC721 is ERC721, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC721("MintableNFT", "MNFT") {
        // Deployer is admin and initial minter
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    // ── Minting ─────────────────────────────────────────────────────────────

    /// @notice Mint tokenId to `to`. Callable only by addresses with MINTER_ROLE.
    ///         The Cartesi application contract calls this via a voucher.
    function mint(address to, uint256 tokenId) external onlyRole(MINTER_ROLE) {
        _mint(to, tokenId);
    }

    // ── Role management ─────────────────────────────────────────────────────

    /// @notice Grant minter role to `account` (admin only).
    ///         Call this with the Cartesi application contract address in test setup.
    function grantMinterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, account);
    }

    /// @notice Revoke minter role.
    function revokeMinterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, account);
    }

    // ── ERC165 ───────────────────────────────────────────────────────────────
    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, AccessControl) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
