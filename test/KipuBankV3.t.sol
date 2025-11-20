// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple Mock ERC20 token for testing (defaults to 18 decimals)
contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract KipuBankV3Test is Test {
    KipuBankV3 bank;
    MockToken tokenA;
    MockToken tokenB;

    address user = address(1);
    address admin;

    function setUp() public {
        admin = address(this); // test contract = admin

        // Deploy mock tokens
        tokenA = new MockToken("MockA", "MKA");
        tokenB = new MockToken("MockB", "MKB");

        // Dummy oracle (we will mock responses)
        bank = new KipuBankV3(
            address(0x123), // oracle
            0,              // USD cap
            0,              // ETH cap
            0               // withdraw cap
        );

        // Transfer tokens to user
        tokenA.transfer(user, 1000 ether);
        tokenB.transfer(user, 1000 ether);
    }

    /// -----------------------------------------
    /// TEST 1 – Deposit ETH
    /// -----------------------------------------
    function testDepositETH() public {
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        bank.depositETH{value: 1 ether}();
        vm.stopPrank();

        assertEq(bank.viewBalance(user, bank.NATIVE()), 1 ether);
    }

    /// -----------------------------------------
    /// TEST 2 – Withdraw ETH
    /// -----------------------------------------
    function testWithdrawETH() public {
        vm.deal(user, 2 ether);

        vm.startPrank(user);
        bank.depositETH{value: 2 ether}();
        bank.withdrawETH(1 ether);
        vm.stopPrank();

        assertEq(bank.viewBalance(user, bank.NATIVE()), 1 ether);
    }

    /// -----------------------------------------
    /// TEST 3 – Deposit ERC20
    /// -----------------------------------------
    function testDepositToken() public {
        vm.startPrank(user);
        tokenA.approve(address(bank), 100 ether);
        bank.depositToken(address(tokenA), 100 ether);
        vm.stopPrank();

        assertEq(bank.viewBalance(user, address(tokenA)), 100 ether);
    }

    /// -----------------------------------------
    /// TEST 4 – Withdraw ERC20
    /// -----------------------------------------
    function testWithdrawToken() public {
        vm.startPrank(user);
        tokenA.approve(address(bank), 100 ether);
        bank.depositToken(address(tokenA), 100 ether);
        bank.withdrawToken(address(tokenA), 50 ether);
        vm.stopPrank();

        assertEq(bank.viewBalance(user, address(tokenA)), 50 ether);
    }

    /// -----------------------------------------
    /// TEST 5 – Withdraw more than balance → REVERT
    /// -----------------------------------------
    function testWithdrawRevert_InsufficientBalance() public {
        vm.startPrank(user);
        tokenA.approve(address(bank), 10 ether);
        bank.depositToken(address(tokenA), 10 ether);

        vm.expectRevert();
        bank.withdrawToken(address(tokenA), 100 ether);
        vm.stopPrank();
    }

    /// -----------------------------------------
    /// TEST 6 – Internal Swap: tokenA → tokenB
    /// -----------------------------------------
    function testSwapInternal() public {
        vm.startPrank(user);
        tokenA.approve(address(bank), 100 ether);
        tokenB.approve(address(bank), 100 ether);

        bank.depositToken(address(tokenA), 100 ether);
        bank.depositToken(address(tokenB), 50 ether);

        bank.swapVaultTokens(address(tokenA), address(tokenB), 20 ether, 1);

        assertEq(bank.viewBalance(user, address(tokenA)), 80 ether);
        assertEq(bank.viewBalance(user, address(tokenB)), 70 ether);
        vm.stopPrank();
    }

    /// -----------------------------------------
    /// TEST 7 – Swap revert for insufficient liquidity
    /// -----------------------------------------
    function testSwapRevert_NoLiquidity() public {
        vm.startPrank(user);
        tokenA.approve(address(bank), 100 ether);
        bank.depositToken(address(tokenA), 100 ether);

        vm.expectRevert();
        bank.swapVaultTokens(address(tokenA), address(tokenB), 10 ether, 1);
        vm.stopPrank();
    }
}
