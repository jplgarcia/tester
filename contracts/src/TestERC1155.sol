// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ERC1155 with open-mint helpers for deposit/withdrawal tests.
///         Supports multiple token IDs and both single & batch minting.
contract TestERC1155 is ERC1155, Ownable {
    // Pre-defined token IDs for convenient testing
    uint256 public constant TOKEN_A = 1;
    uint256 public constant TOKEN_B = 2;
    uint256 public constant TOKEN_C = 3;
    uint256 public constant TOKEN_D = 4;

    constructor() ERC1155("") Ownable(msg.sender) {}

    // ── Single mint ─────────────────────────────────────────────────────────

    /// @notice Mint `amount` of token `id` to `to`. Open for test convenience.
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    // ── Batch mint ──────────────────────────────────────────────────────────

    /// @notice Mint multiple token types in one call.
    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external {
        _mintBatch(to, ids, amounts, "");
    }

    // ── Convenience helper ──────────────────────────────────────────────────

    /// @notice Mint all four pre-defined token IDs to `to` with the given amounts.
    function mintAll(
        address to,
        uint256 amountA,
        uint256 amountB,
        uint256 amountC,
        uint256 amountD
    ) external {
        uint256[] memory ids = new uint256[](4);
        uint256[] memory amounts = new uint256[](4);
        ids[0] = TOKEN_A; amounts[0] = amountA;
        ids[1] = TOKEN_B; amounts[1] = amountB;
        ids[2] = TOKEN_C; amounts[2] = amountC;
        ids[3] = TOKEN_D; amounts[3] = amountD;
        _mintBatch(to, ids, amounts, "");
    }
}
