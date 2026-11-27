// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PayGuard is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable paymentToken;

    address public owner;
    address public executor;

    // Autonomous payment limits (tUSD8 has 6 decimals)
    uint256 public constant MAX_AUTONOMOUS_PAYMENT = 1e6;
    uint256 public constant AUTONOMOUS_SPENDING_LIMIT = 5e6;
    uint256 public constant SPENDING_PERIOD = 30 days;

    // Autonomous spending records
    uint256 public autonomousSpent;
    uint256 public spendingPeriodStart;

    // Prevent duplicate invoice payments
    mapping(bytes32 => bool) public paidInvoices;

    error NotOwner();
    error NotExecutor();
    error ZeroAddress();
    uint256 public vaultBalance;

    error InvalidAmount();
    error InsufficientBalance();
    error TransferFailed();

    error InvalidInvoiceId();
    error InvalidRecipient();
    error PaymentExceedsAutonomousLimit();
    error AutonomousSpendingLimitExceeded();
    error InvoiceAlreadyPaid();

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

    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) revert ZeroAddress();

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

    function setExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();

        address oldExecutor = executor;
        executor = newExecutor;

        emit ExecutorUpdated(oldExecutor, newExecutor);
    }

    function deposit(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidAmount();

        vaultBalance += amount;

        emit Deposited(msg.sender, amount);

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (amount > vaultBalance) revert InsufficientBalance();

        vaultBalance -= amount;

        emit Withdrawn(msg.sender, amount);

        paymentToken.safeTransfer(msg.sender, amount);
    }

    function autoPay(
        bytes32 invoiceId,
        address recipient,
        uint256 amount
    ) external nonReentrant onlyExecutor {
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

        // 4. Check available vault balance
        if (amount > vaultBalance) revert InsufficientBalance();

        // 5. Start or reset the 30-day spending period
        if (
            spendingPeriodStart == 0 ||
            block.timestamp >= spendingPeriodStart + SPENDING_PERIOD
        ) {
            spendingPeriodStart = block.timestamp;
            autonomousSpent = 0;
        }

        // 6. Enforce the 30-day autonomous spending limit
        if (autonomousSpent + amount > AUTONOMOUS_SPENDING_LIMIT) {
            revert AutonomousSpendingLimitExceeded();
        }

        // 7. Update accounting before transferring tokens
        paidInvoices[invoiceId] = true;
        vaultBalance -= amount;
        autonomousSpent += amount;

        // 8. Record the payment
        emit AutonomousPaymentExecuted(invoiceId, recipient, amount);

        // 9. Transfer tUSD8 to the supplier
        paymentToken.safeTransfer(recipient, amount);
    }
}
