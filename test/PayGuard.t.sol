// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PayGuard} from "../contracts/PayGuard.sol";

// Mock tUSD8 token for testing
contract MockTUSD8 is ERC20 {
    constructor() ERC20("Mock tUSD8", "tUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PayGuardTest is Test {
    MockTUSD8 token;
    PayGuard payGuard;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");

    function setUp() public {
        // Deploy mock token
        token = new MockTUSD8();

        // Deploy PayGuard
        payGuard = new PayGuard(address(token));

        // Give the buyer 100 tUSD8
        token.mint(address(this), 100e6);

        // Authorize PayGuard to spend the buyer's tokens
        token.approve(address(payGuard), 100e6);
    }

    // 1. Deployment tests

    function testInitialOwner() public view {
        assertEq(payGuard.owner(), address(this));
    }

    function testInitialTokenAddress() public view {
        assertEq(address(payGuard.paymentToken()), address(token));
    }

    function testInitialExecutorIsZero() public view {
        assertEq(payGuard.executor(), address(0));
    }

    // 2. Executor authorization

    function testSetExecutor() public {
        payGuard.setExecutor(bob);

        assertEq(payGuard.executor(), bob);
    }

    function testOnlyOwnerCanSetExecutor() public {
        vm.prank(bob);

        vm.expectRevert(PayGuard.NotOwner.selector);
        payGuard.setExecutor(alice);
    }

    // 3. Deposit tests

    function testDeposit() public {
        uint256 amount = 10e6;

        payGuard.deposit(amount);

        assertEq(payGuard.vaultBalance(), amount);
        assertEq(token.balanceOf(address(payGuard)), amount);
        assertEq(token.balanceOf(address(this)), 90e6);
    }

    function testCannotDepositZero() public {
        vm.expectRevert(PayGuard.InvalidAmount.selector);

        payGuard.deposit(0);
    }

    // 4. Withdrawal tests

    function testWithdraw() public {
        uint256 depositAmount = 10e6;
        uint256 withdrawAmount = 4e6;

        payGuard.deposit(depositAmount);
        payGuard.withdraw(withdrawAmount);

        assertEq(payGuard.vaultBalance(), 6e6);
        assertEq(token.balanceOf(address(this)), 94e6);
    }

    function testCannotWithdrawZero() public {
        vm.expectRevert(PayGuard.InvalidAmount.selector);

        payGuard.withdraw(0);
    }

    function testCannotWithdrawMoreThanBalance() public {
        vm.expectRevert(PayGuard.InsufficientBalance.selector);

        payGuard.withdraw(1e6);
    }

    function testOnlyOwnerCanWithdraw() public {
        payGuard.deposit(10e6);

        vm.prank(bob);

        vm.expectRevert(PayGuard.NotOwner.selector);
        payGuard.withdraw(5e6);
    }

    function testAutoPay() public {
        // Buyer deposits 5 tUSD8
        payGuard.deposit(5e6);

        // Buyer authorizes Bob as executor
        payGuard.setExecutor(bob);

        // Generate an invoice ID
        bytes32 invoiceId = keccak256("INV-001");

        // Bob executes a payment of 1 tUSD8 to Alice
        vm.prank(bob);
        payGuard.autoPay(invoiceId, alice, 1e6);

        // Verify balances
        assertEq(token.balanceOf(alice), 1e6);
        assertEq(payGuard.vaultBalance(), 4e6);

        // Verify spending records
        assertEq(payGuard.autonomousSpent(), 1e6);
        assertTrue(payGuard.paidInvoices(invoiceId));
    }

    function testOnlyExecutorCanAutoPay() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-002");

        // Alice attempts to execute a payment
        vm.prank(alice);
        vm.expectRevert(PayGuard.NotExecutor.selector);

        payGuard.autoPay(invoiceId, alice, 1e6);
    }

    function testCannotPayInvoiceTwice() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-003");

        // First payment
        vm.prank(bob);
        payGuard.autoPay(invoiceId, alice, 1e6);

        // Attempt to pay the same invoice again
        vm.prank(bob);
        vm.expectRevert(PayGuard.InvoiceAlreadyPaid.selector);

        payGuard.autoPay(invoiceId, alice, 1e6);
    }

    function testCannotExceedMaxAutonomousPayment() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-004");

        vm.prank(bob);
        vm.expectRevert(PayGuard.PaymentExceedsAutonomousLimit.selector);

        payGuard.autoPay(invoiceId, alice, 1.5e6);
    }

    function testCannotExceed30DaySpendingLimit() public {
        payGuard.deposit(6e6);
        payGuard.setExecutor(bob);

        // Five successful payments of 1 tUSD8 each
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 invoiceId = keccak256(abi.encode(i));

            vm.prank(bob);
            payGuard.autoPay(invoiceId, alice, 1e6);
        }

        // Spending should now equal 5 tUSD8
        assertEq(payGuard.autonomousSpent(), 5e6);

        // Attempt a sixth payment
        bytes32 sixthInvoice = keccak256("INV-006");

        vm.prank(bob);
        vm.expectRevert(PayGuard.AutonomousSpendingLimitExceeded.selector);

        payGuard.autoPay(sixthInvoice, alice, 1e6);
    }

    function testSpendingLimitResetsAfter30Days() public {
        payGuard.deposit(10e6);
        payGuard.setExecutor(bob);

        // Spend the full 5 tUSD8 allowance
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 invoiceId = keccak256(abi.encode(i));

            vm.prank(bob);
            payGuard.autoPay(invoiceId, alice, 1e6);
        }

        assertEq(payGuard.autonomousSpent(), 5e6);

        // Move blockchain time forward by 30 days
        vm.warp(block.timestamp + 30 days);

        // Execute another payment
        bytes32 newInvoice = keccak256("INV-NEW-PERIOD");

        vm.prank(bob);
        payGuard.autoPay(newInvoice, alice, 1e6);

        // Spending counter should have reset
        assertEq(payGuard.autonomousSpent(), 1e6);

        // Verify the new payment succeeded
        assertEq(token.balanceOf(alice), 6e6);
        assertEq(payGuard.vaultBalance(), 4e6);
    }
}
