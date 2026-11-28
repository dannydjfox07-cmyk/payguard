// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PayGuard is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable paymentToken;

    address public immutable owner;
    address public executor;

    // Autonomous payment limits (tUSD8 has 6 decimals)
    uint256 public constant MAX_AUTONOMOUS_PAYMENT = 1e6;
    uint256 public constant AUTONOMOUS_SPENDING_LIMIT = 5e6;
    uint256 public constant SPENDING_PERIOD = 30 days;

    // Rolling 30-day autonomous spending records
    struct AutonomousPayment {
        uint256 timestamp;
        uint256 amount;
    }

    mapping(uint256 => AutonomousPayment) public autonomousPayments;

    uint256 public paymentHead;
    uint256 public paymentTail;
    uint256 public autonomousSpentRolling;

    uint256 public constant MAX_PAYMENT_RECORDS = 1000;

    // Prevent duplicate invoice payments
    mapping(bytes32 => bool) public paidInvoices;
    mapping(bytes32 => bool) public rejectedInvoices;

    struct ApprovalRequest {
        address recipient;
        uint256 amount;
        bool exists;
    }

    mapping(bytes32 => ApprovalRequest) public approvalRequests;

    error NotOwner();
    error NotExecutor();
    error ZeroAddress();
    uint256 public vaultBalance;
    uint256 public reservedBalance;

    error InvalidAmount();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidTokenAddress();

    error InvalidInvoiceId();
    error InvalidRecipient();
    error PaymentExceedsAutonomousLimit();
    error AutonomousSpendingLimitExceeded();
    error InvoiceAlreadyPaid();
    error InvalidTokenDecimals();

    error ApprovalRequestAlreadyExists();
    error ApprovalRequestNotFound();
    error InvoiceAlreadyRejected();
    error InvalidExecutorAddress();
    error VaultInsolvent();
    event Recapitalized(address indexed account, uint256 amount);
    error TooManyPaymentRecords();

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    event AutonomousPaymentExecuted(
        bytes32 indexed invoiceId,
        address indexed recipient,
        uint256 amount
    );

    event ExecutorUpdated(
        address indexed oldExecutor,
        address indexed newExecutor
    );

    event HumanPaymentRequested(
        bytes32 indexed invoiceId,
        address indexed recipient,
        uint256 amount
    );

    event HumanPaymentApproved(
        bytes32 indexed invoiceId,
        address indexed recipient,
        uint256 amount
    );

    event HumanPaymentRejected(bytes32 indexed invoiceId);

    event ExpiredPaymentsCleaned(
        address indexed caller,
        uint256 recordsCleaned
    );

    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (tokenAddress.code.length == 0) revert InvalidTokenAddress();

        if (IERC20Metadata(tokenAddress).decimals() != 6) {
            revert InvalidTokenDecimals();
        }

        paymentToken = IERC20(tokenAddress);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    uint256 public constant MAX_CLEANUP_BATCH = 50;

    function _removeExpiredPayments() private returns (uint256 cleaned) {
        uint256 cutoff = block.timestamp > SPENDING_PERIOD
            ? block.timestamp - SPENDING_PERIOD
            : 0;

        while (paymentHead < paymentTail && cleaned < MAX_CLEANUP_BATCH) {
            AutonomousPayment storage payment = autonomousPayments[paymentHead];

            if (payment.timestamp > cutoff) {
                break;
            }

            autonomousSpentRolling -= payment.amount;

            delete autonomousPayments[paymentHead];

            paymentHead++;
            cleaned++;
        }
    }

    function setExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        if (newExecutor == address(this)) revert InvalidExecutorAddress();

        address oldExecutor = executor;
        executor = newExecutor;

        emit ExecutorUpdated(oldExecutor, newExecutor);
    }

    function _checkSolvency() private view {
        if (paymentToken.balanceOf(address(this)) < vaultBalance) {
            revert VaultInsolvent();
        }
    }

    function deposit(uint256 amount) external nonReentrant onlyOwner {
        _checkSolvency();
        if (amount == 0) revert InvalidAmount();

        uint256 balanceBefore = paymentToken.balanceOf(address(this));

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 balanceAfter = paymentToken.balanceOf(address(this));

        if (balanceAfter - balanceBefore != amount) {
            revert TransferFailed();
        }

        vaultBalance += amount;

        emit Deposited(msg.sender, amount);
    }

    function cleanupExpiredPayments() external returns (uint256 cleaned) {
        cleaned = _removeExpiredPayments();

        if (cleaned > 0) {
            emit ExpiredPaymentsCleaned(msg.sender, cleaned);
        }
    }
    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        _checkSolvency();
        if (amount == 0) revert InvalidAmount();
        if (amount > vaultBalance - reservedBalance) {
            revert InsufficientBalance();
        }

        vaultBalance -= amount;

        emit Withdrawn(msg.sender, amount);

        _transferExact(msg.sender, amount);
    }

    function autoPay(
        bytes32 invoiceId,
        address recipient,
        uint256 amount
    ) external nonReentrant onlyExecutor {
        _checkSolvency();
        // 1. Validate inputs
        if (invoiceId == bytes32(0)) revert InvalidInvoiceId();
        if (recipient == address(0)) revert InvalidRecipient();
        if (recipient == address(this)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();

        // 2. Enforce maximum payment per transaction
        if (amount > MAX_AUTONOMOUS_PAYMENT) {
            revert PaymentExceedsAutonomousLimit();
        }

        // 3. Prevent duplicate invoice payments
        if (paidInvoices[invoiceId]) revert InvoiceAlreadyPaid();
        if (rejectedInvoices[invoiceId]) revert InvoiceAlreadyRejected();

        if (approvalRequests[invoiceId].exists) {
            revert ApprovalRequestAlreadyExists();
        }

        // 4. Check available vault balance
        if (amount > vaultBalance - reservedBalance) {
            revert InsufficientBalance();
        }

        // 5. Remove payments outside the rolling 30-day window.
        _removeExpiredPayments();

        // 6. Enforce the rolling 30-day spending limit.
        if (autonomousSpentRolling + amount > AUTONOMOUS_SPENDING_LIMIT) {
            revert AutonomousSpendingLimitExceeded();
        }

        // 7. Prevent an excessive number of payment records.
        if (paymentTail - paymentHead >= MAX_PAYMENT_RECORDS) {
            revert TooManyPaymentRecords();
        }
        // 8. Update payment accounting
        paidInvoices[invoiceId] = true;
        vaultBalance -= amount;

        // 9. Record autonomous spending
        autonomousSpentRolling += amount;

        autonomousPayments[paymentTail] = AutonomousPayment({
            timestamp: block.timestamp,
            amount: amount
        });

        paymentTail++;

        // 10. Record the payment
        emit AutonomousPaymentExecuted(invoiceId, recipient, amount);

        // 11. Transfer tUSD8 to the supplier
        _transferExact(recipient, amount);
    }

    function requestHumanApproval(
        bytes32 invoiceId,
        address recipient,
        uint256 amount
    ) external nonReentrant onlyExecutor {
        _checkSolvency();
        if (invoiceId == bytes32(0)) revert InvalidInvoiceId();
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (amount == 0) revert InvalidAmount();

        if (paidInvoices[invoiceId]) revert InvoiceAlreadyPaid();
        if (rejectedInvoices[invoiceId]) revert InvoiceAlreadyRejected();
        if (approvalRequests[invoiceId].exists) {
            revert ApprovalRequestAlreadyExists();
        }

        if (amount > vaultBalance - reservedBalance) {
            revert InsufficientBalance();
        }

        approvalRequests[invoiceId] = ApprovalRequest({
            recipient: recipient,
            amount: amount,
            exists: true
        });

        reservedBalance += amount;

        emit HumanPaymentRequested(invoiceId, recipient, amount);
    }

    function approvePayment(bytes32 invoiceId) external nonReentrant onlyOwner {
        _checkSolvency();
        ApprovalRequest memory request = approvalRequests[invoiceId];

        if (!request.exists) revert ApprovalRequestNotFound();

        // Release the reservation
        reservedBalance -= request.amount;

        // Update payment accounting
        paidInvoices[invoiceId] = true;
        vaultBalance -= request.amount;

        // Remove the pending request
        delete approvalRequests[invoiceId];

        // Record approval
        emit HumanPaymentApproved(invoiceId, request.recipient, request.amount);

        // Transfer tokens to supplier
        _transferExact(request.recipient, request.amount);
    }

    function rejectPayment(bytes32 invoiceId) external nonReentrant onlyOwner {
        ApprovalRequest memory request = approvalRequests[invoiceId];

        if (!request.exists) revert ApprovalRequestNotFound();

        reservedBalance -= request.amount;

        rejectedInvoices[invoiceId] = true;

        delete approvalRequests[invoiceId];

        emit HumanPaymentRejected(invoiceId);
    }

    function recapitalize(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidAmount();

        uint256 balanceBefore = paymentToken.balanceOf(address(this));

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 balanceAfter = paymentToken.balanceOf(address(this));

        if (balanceAfter - balanceBefore != amount) {
            revert TransferFailed();
        }

        emit Recapitalized(msg.sender, amount);
    }

    function _transferExact(address recipient, uint256 amount) private {
        _checkSolvency();
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = paymentToken.balanceOf(recipient);

        paymentToken.safeTransfer(recipient, amount);

        uint256 contractBalanceAfter = paymentToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = paymentToken.balanceOf(recipient);

        // Verify PayGuard lost exactly the requested amount.
        if (
            contractBalanceBefore < contractBalanceAfter ||
            contractBalanceBefore - contractBalanceAfter != amount
        ) {
            revert TransferFailed();
        }

        // Verify the recipient received exactly the requested amount.
        if (
            recipientBalanceAfter < recipientBalanceBefore ||
            recipientBalanceAfter - recipientBalanceBefore != amount
        ) {
            revert TransferFailed();
        }
    }
}
