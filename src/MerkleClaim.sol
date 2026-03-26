// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MerkleClaim — Legacy Holder Airdrop
/// @notice 68,160 legacy holders can claim tokens proportional to their snapshot balance.
///         Uses Merkle proof for gas-efficient verification.
contract MerkleClaim {
    IERC20 public immutable TOKEN;
    address public immutable OWNER;
    bytes32 public merkleRoot;
    uint256 public claimDeadline;
    uint256 public totalClaimed;

    mapping(address => bool) public hasClaimed;

    event Claimed(address indexed account, uint256 amount);
    event MerkleRootSet(bytes32 root, uint256 deadline);
    event Swept(address indexed to, uint256 amount);

    error AlreadyClaimed();
    error InvalidProof();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error NotOwner();
    error NotConfigured();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    constructor(address _token) {
        if (_token == address(0)) revert ZeroAddress();
        TOKEN = IERC20(_token);
        OWNER = msg.sender;
    }

    /// @notice Set the Merkle root and open the claim window.
    function configure(bytes32 _root, uint256 _duration) external onlyOwner {
        merkleRoot = _root;
        claimDeadline = block.timestamp + _duration;
        emit MerkleRootSet(_root, claimDeadline);
    }

    /// @notice Claim tokens using a Merkle proof.
    function claim(uint256 amount, bytes32[] calldata proof) external {
        if (merkleRoot == bytes32(0)) revert NotConfigured();
        if (block.timestamp > claimDeadline) revert ClaimWindowClosed();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        hasClaimed[msg.sender] = true;
        totalClaimed += amount;

        bool ok = TOKEN.transfer(msg.sender, amount);
        require(ok, "Transfer failed");

        emit Claimed(msg.sender, amount);
    }

    /// @notice Sweep unclaimed tokens after the claim window closes.
    function sweep(address to) external onlyOwner {
        if (block.timestamp <= claimDeadline) revert ClaimWindowOpen();
        uint256 remaining = TOKEN.balanceOf(address(this));
        bool ok = TOKEN.transfer(to, remaining);
        require(ok, "Transfer failed");
        emit Swept(to, remaining);
    }

    function canClaim(address account) external view returns (bool) {
        return !hasClaimed[account] && merkleRoot != bytes32(0) && block.timestamp <= claimDeadline;
    }
}
