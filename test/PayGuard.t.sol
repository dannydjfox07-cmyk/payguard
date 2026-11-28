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

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract Mock18DecimalToken is ERC20 {
    constructor() ERC20("Mock 18 Decimal", "M18") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferToken is ERC20 {
    address public feeCollector = address(0xdead);
    bool public feeEnabled = true;

    constructor() ERC20("Fee Token", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (feeEnabled && from != address(0) && to != address(0)) {
            uint256 fee = (value * 200) / 10_000;

            super._update(from, feeCollector, fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
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
        assertEq(payGuard.autonomousSpentRolling(), 1e6);
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
        assertEq(payGuard.autonomousSpentRolling(), 5e6);

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

        assertEq(payGuard.autonomousSpentRolling(), 5e6);

        // Move blockchain time forward by 30 days
        vm.warp(block.timestamp + 30 days);

        // Execute another payment
        bytes32 newInvoice = keccak256("INV-NEW-PERIOD");

        vm.prank(bob);
        payGuard.autoPay(newInvoice, alice, 1e6);

        // Spending counter should have reset
        assertEq(payGuard.autonomousSpentRolling(), 1e6);

        // Verify the new payment succeeded
        assertEq(token.balanceOf(alice), 6e6);
        assertEq(payGuard.vaultBalance(), 4e6);
    }

    function testHumanApprovalPayment() public {
        // Buyer deposits 5 tUSD8
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-APPROVAL-001");

        // Bob requests a 2 tUSD8 payment
        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 2e6);

        // Verify funds are reserved
        assertEq(payGuard.reservedBalance(), 2e6);
        assertEq(payGuard.vaultBalance(), 5e6);

        // Alice has not received anything yet
        assertEq(token.balanceOf(alice), 0);

        // Buyer approves the payment
        payGuard.approvePayment(invoiceId);

        // Verify payment
        assertEq(token.balanceOf(alice), 2e6);
        assertEq(payGuard.vaultBalance(), 3e6);
        assertEq(payGuard.reservedBalance(), 0);

        // Verify invoice is marked paid
        assertTrue(payGuard.paidInvoices(invoiceId));

        // Human-approved payments don't count toward autonomous spending
        assertEq(payGuard.autonomousSpentRolling(), 0);
    }

    function testOnlyOwnerCanApprovePayment() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-APPROVAL-002");

        // Bob creates a payment request
        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 2e6);

        // Bob attempts to approve his own request
        vm.prank(bob);
        vm.expectRevert(PayGuard.NotOwner.selector);

        payGuard.approvePayment(invoiceId);

        // Verify nothing was transferred
        assertEq(token.balanceOf(alice), 0);

        // Verify funds remain reserved
        assertEq(payGuard.reservedBalance(), 2e6);

        // Verify vault accounting remains unchanged
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testCannotWithdrawReservedFunds() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-APPROVAL-003");

        // Bob requests 4 tUSD8 for Alice
        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 4e6);

        // Buyer attempts to withdraw 2 tUSD8
        // Only 1 tUSD8 is actually available
        vm.expectRevert(PayGuard.InsufficientBalance.selector);
        payGuard.withdraw(2e6);

        // Verify balances remain unchanged
        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(payGuard.reservedBalance(), 4e6);
        assertEq(token.balanceOf(address(this)), 95e6);
    }

    function testCannotOvercommitReservedFunds() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceA = keccak256("INV-RESERVE-A");
        bytes32 invoiceB = keccak256("INV-RESERVE-B");

        // First request reserves 3 tUSD8
        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceA, alice, 3e6);

        assertEq(payGuard.reservedBalance(), 3e6);

        // Second request attempts to reserve another 3 tUSD8
        vm.prank(bob);
        vm.expectRevert(PayGuard.InsufficientBalance.selector);

        payGuard.requestHumanApproval(invoiceB, alice, 3e6);

        // Verify accounting remains correct
        assertEq(payGuard.reservedBalance(), 3e6);
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testRejectHumanPayment() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-REJECT-001");

        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 3e6);

        // Buyer rejects the request
        payGuard.rejectPayment(invoiceId);

        assertEq(payGuard.reservedBalance(), 0);
        assertEq(payGuard.vaultBalance(), 5e6);
        assertTrue(payGuard.rejectedInvoices(invoiceId));
        (, , bool exists) = payGuard.approvalRequests(invoiceId);
        assertFalse(exists);
        assertEq(token.balanceOf(alice), 0);
    }

    function testRejectedInvoiceCannotBeResubmittedOrPaid() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INV-REJECT-002");

        // Bob requests human approval
        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 3e6);

        // Buyer rejects it
        payGuard.rejectPayment(invoiceId);

        // Bob cannot submit the same invoice again
        vm.prank(bob);
        vm.expectRevert(PayGuard.InvoiceAlreadyRejected.selector);
        payGuard.requestHumanApproval(invoiceId, alice, 3e6);

        // Bob cannot bypass rejection through autonomous payment
        vm.prank(bob);
        vm.expectRevert(PayGuard.InvoiceAlreadyRejected.selector);
        payGuard.autoPay(invoiceId, alice, 0.5e6);

        // Buyer cannot approve an already rejected request
        vm.expectRevert(PayGuard.ApprovalRequestNotFound.selector);
        payGuard.approvePayment(invoiceId);

        assertTrue(payGuard.rejectedInvoices(invoiceId));
        assertEq(payGuard.reservedBalance(), 0);
        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function testAutoPayCannotConsumeReservedFunds() public {
        payGuard.deposit(5e6);

        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("human-invoice");

        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 4.5e6);

        vm.prank(bob);
        vm.expectRevert(PayGuard.InsufficientBalance.selector);
        payGuard.autoPay(keccak256("autonomous-invoice"), alice, 1e6);

        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(payGuard.reservedBalance(), 4.5e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function testCannotDeployWithZeroTokenAddress() public {
        vm.expectRevert(PayGuard.ZeroAddress.selector);
        new PayGuard(address(0));
    }

    function testCannotDeployWithEOAAsTokenAddress() public {
        address fakeToken = makeAddr("fakeToken");

        vm.expectRevert(PayGuard.InvalidTokenAddress.selector);
        new PayGuard(fakeToken);
    }

    function testCannotSetContractAsExecutor() public {
        vm.expectRevert(PayGuard.InvalidExecutorAddress.selector);
        payGuard.setExecutor(address(payGuard));
    }

    function testCannotDeployWith18DecimalToken() public {
        Mock18DecimalToken token18 = new Mock18DecimalToken();

        vm.expectRevert(PayGuard.InvalidTokenDecimals.selector);
        new PayGuard(address(token18));
    }

    function testDepositRejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        PayGuard feePayGuard = new PayGuard(address(feeToken));

        feeToken.mint(address(this), 10e6);
        feeToken.approve(address(feePayGuard), 10e6);

        vm.expectRevert(PayGuard.TransferFailed.selector);
        feePayGuard.deposit(5e6);

        assertEq(feePayGuard.vaultBalance(), 0);
        assertEq(feeToken.balanceOf(address(feePayGuard)), 0);
        assertEq(feeToken.balanceOf(address(this)), 10e6);
    }

    function testAutoPayRejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.setFeeEnabled(false);
        PayGuard feePayGuard = new PayGuard(address(feeToken));

        feeToken.mint(address(this), 5e6);
        feeToken.approve(address(feePayGuard), 5e6);
        feePayGuard.deposit(5e6);
        feeToken.setFeeEnabled(true);

        feePayGuard.setExecutor(bob);

        vm.prank(bob);
        vm.expectRevert(PayGuard.TransferFailed.selector);
        feePayGuard.autoPay(keccak256("invoice-1"), alice, 1e6);

        assertEq(feePayGuard.vaultBalance(), 5e6);
        assertEq(feeToken.balanceOf(alice), 0);
        assertFalse(feePayGuard.paidInvoices(keccak256("invoice-1")));
    }

    function testHumanApprovalRejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.setFeeEnabled(false);
        PayGuard feePayGuard = new PayGuard(address(feeToken));

        feeToken.mint(address(this), 5e6);
        feeToken.approve(address(feePayGuard), 5e6);
        feePayGuard.deposit(5e6);
        feeToken.setFeeEnabled(true);

        feePayGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("invoice-2");

        vm.prank(bob);
        feePayGuard.requestHumanApproval(invoiceId, alice, 2e6);

        vm.expectRevert(PayGuard.TransferFailed.selector);
        feePayGuard.approvePayment(invoiceId);

        assertEq(feePayGuard.vaultBalance(), 5e6);
        assertEq(feePayGuard.reservedBalance(), 2e6);
        assertEq(feeToken.balanceOf(alice), 0);
        (, , bool exists) = feePayGuard.approvalRequests(invoiceId);
        assertTrue(exists);
    }

    function testWithdrawRejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.setFeeEnabled(false);
        PayGuard feePayGuard = new PayGuard(address(feeToken));

        feeToken.mint(address(this), 5e6);
        feeToken.approve(address(feePayGuard), 5e6);
        feePayGuard.deposit(5e6);
        feeToken.setFeeEnabled(true);

        vm.expectRevert(PayGuard.TransferFailed.selector);
        feePayGuard.withdraw(2e6);

        assertEq(feePayGuard.vaultBalance(), 5e6);
        assertEq(feeToken.balanceOf(address(feePayGuard)), 5e6);
    }

    function testCannotWithdrawWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);

        // Simulate an unexpected loss of 1 tUSD8.
        token.burn(address(payGuard), 1e6);

        assertEq(token.balanceOf(address(payGuard)), 4e6);
        assertEq(payGuard.vaultBalance(), 5e6);

        vm.expectRevert(PayGuard.VaultInsolvent.selector);
        payGuard.withdraw(1e6);

        // Accounting must remain unchanged.
        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(token.balanceOf(address(payGuard)), 4e6);
    }

    function testRecapitalizeRestoresSolvency() public {
        payGuard.deposit(5e6);

        // Simulate an unexpected loss of 1 tUSD8.
        token.burn(address(payGuard), 1e6);

        assertEq(token.balanceOf(address(payGuard)), 4e6);
        assertEq(payGuard.vaultBalance(), 5e6);

        // Owner replenishes the missing 1 tUSD8.
        payGuard.recapitalize(1e6);

        // Actual balance is restored, but accounting is unchanged.
        assertEq(token.balanceOf(address(payGuard)), 5e6);
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testCannotDepositWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);

        token.burn(address(payGuard), 1e6);

        vm.expectRevert(PayGuard.VaultInsolvent.selector);
        payGuard.deposit(1e6);

        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(token.balanceOf(address(payGuard)), 4e6);
    }

    function testCannotAutoPayWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        token.burn(address(payGuard), 1e6);

        vm.prank(bob);
        vm.expectRevert(PayGuard.VaultInsolvent.selector);
        payGuard.autoPay(keccak256("INVOICE-INSOLVENT"), alice, 1e6);

        assertFalse(payGuard.paidInvoices(keccak256("INVOICE-INSOLVENT")));
        assertEq(token.balanceOf(alice), 0);
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testCannotRequestHumanApprovalWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        token.burn(address(payGuard), 1e6);

        bytes32 invoiceId = keccak256("INVOICE-REVIEW");

        vm.prank(bob);
        vm.expectRevert(PayGuard.VaultInsolvent.selector);
        payGuard.requestHumanApproval(invoiceId, alice, 2e6);

        (, , bool exists) = payGuard.approvalRequests(invoiceId);

        assertFalse(exists);
        assertEq(payGuard.reservedBalance(), 0);
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testCannotApprovePaymentWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INVOICE-APPROVAL");

        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 2e6);

        assertEq(payGuard.reservedBalance(), 2e6);

        // Simulate an unexpected loss after the request was created.
        token.burn(address(payGuard), 1e6);

        vm.expectRevert(PayGuard.VaultInsolvent.selector);
        payGuard.approvePayment(invoiceId);

        (, , bool exists) = payGuard.approvalRequests(invoiceId);

        assertTrue(exists);
        assertFalse(payGuard.paidInvoices(invoiceId));
        assertEq(payGuard.reservedBalance(), 2e6);
        assertEq(payGuard.vaultBalance(), 5e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function testCanRejectPaymentWhenVaultIsInsolvent() public {
        payGuard.deposit(5e6);
        payGuard.setExecutor(bob);

        bytes32 invoiceId = keccak256("INVOICE-REJECT-INSOLVENT");

        vm.prank(bob);
        payGuard.requestHumanApproval(invoiceId, alice, 2e6);

        token.burn(address(payGuard), 1e6);

        // Owner must still be able to release reserved funds.
        payGuard.rejectPayment(invoiceId);

        (, , bool exists) = payGuard.approvalRequests(invoiceId);

        assertFalse(exists);
        assertTrue(payGuard.rejectedInvoices(invoiceId));
        assertEq(payGuard.reservedBalance(), 0);
        assertEq(payGuard.vaultBalance(), 5e6);
    }

    function testRollingWindowRemovesOnlyExpiredPayments() public {
        payGuard.deposit(10e6);
        payGuard.setExecutor(bob);

        // Day 1: two payments.
        vm.startPrank(bob);
        payGuard.autoPay(keccak256("ROLL-1"), alice, 1e6);
        payGuard.autoPay(keccak256("ROLL-2"), alice, 1e6);
        vm.stopPrank();

        // Day 10: one payment.
        vm.warp(block.timestamp + 9 days);

        vm.prank(bob);
        payGuard.autoPay(keccak256("ROLL-3"), alice, 1e6);

        // Day 20: two payments.
        vm.warp(block.timestamp + 10 days);

        vm.startPrank(bob);
        payGuard.autoPay(keccak256("ROLL-4"), alice, 1e6);
        payGuard.autoPay(keccak256("ROLL-5"), alice, 1e6);
        vm.stopPrank();

        assertEq(payGuard.autonomousSpentRolling(), 5e6);

        // Day 31: only the two Day 1 payments expire.
        vm.warp(block.timestamp + 11 days);

        vm.prank(bob);
        payGuard.autoPay(keccak256("ROLL-6"), alice, 1e6);

        // 3 remaining + 1 new = 4 tUSD8.
        assertEq(payGuard.autonomousSpentRolling(), 4e6);
    }

    function testPaymentExpiresAtExactly30Days() public {
        payGuard.deposit(10e6);
        payGuard.setExecutor(bob);

        // Make five separate payments of 1 tUSD8.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            payGuard.autoPay(keccak256(abi.encode("BOUNDARY", i)), alice, 1e6);
        }

        assertEq(payGuard.autonomousSpentRolling(), 5e6);

        // Advance exactly 30 days.
        vm.warp(block.timestamp + 30 days);

        // All five previous payments should now be expired.
        vm.prank(bob);
        payGuard.autoPay(keccak256("BOUNDARY-NEW"), alice, 1e6);

        assertEq(payGuard.autonomousSpentRolling(), 1e6);
    }

    function testCleanupProcessesMaximum50Records() public {
        payGuard.deposit(1e6);
        payGuard.setExecutor(bob);

        // Create 51 autonomous payment records.
        for (uint256 i = 0; i < 51; i++) {
            vm.prank(bob);
            payGuard.autoPay(keccak256(abi.encode("BATCH", i)), alice, 1);
        }

        assertEq(payGuard.paymentHead(), 0);
        assertEq(payGuard.paymentTail(), 51);
        assertEq(payGuard.autonomousSpentRolling(), 51);

        // Expire all 51 payments.
        vm.warp(block.timestamp + 30 days);

        // This payment triggers cleanup.
        vm.prank(bob);
        payGuard.autoPay(keccak256("BATCH-NEW"), alice, 1);

        // Only 50 expired records should have been removed.
        assertEq(payGuard.paymentHead(), 50);

        // One old record remains, followed by the new payment.
        assertEq(payGuard.paymentTail(), 52);

        // 1 expired record + 1 new payment.
        assertEq(payGuard.autonomousSpentRolling(), 2);
    }

    function testPermissionlessCleanupProcessesBatches() public {
        payGuard.deposit(1e6);
        payGuard.setExecutor(bob);

        // Create 51 autonomous payment records.
        for (uint256 i = 0; i < 51; i++) {
            vm.prank(bob);
            payGuard.autoPay(keccak256(abi.encode("CLEANUP", i)), alice, 1);
        }

        assertEq(payGuard.paymentTail(), 51);
        assertEq(payGuard.autonomousSpentRolling(), 51);

        // Expire all 51 payments.
        vm.warp(block.timestamp + 30 days);

        // Alice is not the owner or executor.
        // She should still be able to perform cleanup.
        vm.prank(alice);
        uint256 firstBatch = payGuard.cleanupExpiredPayments();

        assertEq(firstBatch, 50);
        assertEq(payGuard.paymentHead(), 50);
        assertEq(payGuard.autonomousSpentRolling(), 1);

        // Anyone can clean the remaining record.
        vm.prank(bob);
        uint256 secondBatch = payGuard.cleanupExpiredPayments();

        assertEq(secondBatch, 1);
        assertEq(payGuard.paymentHead(), 51);
        assertEq(payGuard.autonomousSpentRolling(), 0);
    }
}
