// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleClaim} from "../src/MerkleClaim.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MerkleClaimTest is Test {
    MerkleClaim public claim;
    MockERC20 public token;
    address public owner;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    // Pre-computed Merkle tree for alice=100e18, bob=200e18
    bytes32 public leafAlice;
    bytes32 public leafBob;
    bytes32 public root;

    function setUp() public {
        owner = address(this);
        token = new MockERC20("SMC Token", "SMC");
        claim = new MerkleClaim(address(token));

        // Compute leaves
        leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, 100e18))));
        leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, 200e18))));

        // Simple 2-leaf Merkle tree
        if (leafAlice <= leafBob) {
            root = keccak256(abi.encodePacked(leafAlice, leafBob));
        } else {
            root = keccak256(abi.encodePacked(leafBob, leafAlice));
        }

        // Fund claim contract
        token.mint(address(claim), 300e18);

        // Configure with 30-day window
        claim.configure(root, 30 days);
    }

    function test_claim() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;

        vm.prank(alice);
        claim.claim(100e18, proof);

        assertTrue(claim.hasClaimed(alice));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(claim.totalClaimed(), 100e18);
    }

    function test_revertDoubleClaim() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;

        vm.prank(alice);
        claim.claim(100e18, proof);

        vm.expectRevert(MerkleClaim.AlreadyClaimed.selector);
        vm.prank(alice);
        claim.claim(100e18, proof);
    }

    function test_revertInvalidProof() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(uint256(1)); // wrong proof

        vm.expectRevert(MerkleClaim.InvalidProof.selector);
        vm.prank(alice);
        claim.claim(100e18, proof);
    }

    function test_revertClaimWindowClosed() public {
        vm.warp(block.timestamp + 31 days);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;

        vm.expectRevert(MerkleClaim.ClaimWindowClosed.selector);
        vm.prank(alice);
        claim.claim(100e18, proof);
    }

    function test_revertNotConfigured() public {
        MerkleClaim newClaim = new MerkleClaim(address(token));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;

        vm.expectRevert(MerkleClaim.NotConfigured.selector);
        vm.prank(alice);
        newClaim.claim(100e18, proof);
    }

    function test_sweep() public {
        vm.warp(block.timestamp + 31 days);
        claim.sweep(owner);
        assertEq(token.balanceOf(owner), 300e18);
    }

    function test_revertSweepTooEarly() public {
        vm.expectRevert(MerkleClaim.ClaimWindowOpen.selector);
        claim.sweep(owner);
    }

    function test_canClaim() public {
        assertTrue(claim.canClaim(alice));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;
        vm.prank(alice);
        claim.claim(100e18, proof);

        assertFalse(claim.canClaim(alice));
    }

    function test_revertZeroAddressConstructor() public {
        vm.expectRevert(MerkleClaim.ZeroAddress.selector);
        new MerkleClaim(address(0));
    }
}
