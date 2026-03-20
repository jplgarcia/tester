// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Bare-bones ERC721 for deposit/withdrawal tests.
///         Anyone can mint — owner can also batch-mint.
contract TestERC721 is ERC721, Ownable {
    constructor() ERC721("TestNFT", "TNFT") Ownable(msg.sender) {}

    /// @notice Mint a single token. Open to anyone for testing convenience.
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @notice Batch-mint several token IDs at once.
    function batchMint(address to, uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _mint(to, tokenIds[i]);
        }
    }
}
