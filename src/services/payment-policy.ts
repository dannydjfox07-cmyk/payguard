import { parseUnits } from "viem";

import { paymentPolicy } from "../config/payment-policy";

import type { Invoice } from "../invoice/invoice-types";
import type { VerificationResult } from "./verification";

export type PaymentDecision =
  | "AUTO_APPROVED"
  | "HUMAN_REVIEW"
  | "BLOCKED";

export interface PaymentPolicyInput {
  invoice: Invoice;
  verification: VerificationResult;

  isDuplicate: boolean;

  // Total spending already made this month
  monthlySpend: string;
}

export interface PaymentPolicyResult {
  decision: PaymentDecision;
  reasons: string[];
  amount: string;
  monthlySpend: string;
}

function toTokenUnits(amount: string): bigint {
  if (!/^\d+(\.\d{1,6})?$/.test(amount)) {
    throw new Error("Invalid tUSD8 amount.");
  }

  return parseUnits(amount, 6);
}

export function evaluatePaymentPolicy(
  input: PaymentPolicyInput,
): PaymentPolicyResult {

  const { invoice, verification, isDuplicate, monthlySpend } = input;

  const amount = toTokenUnits(invoice.amount);
  const currentMonthlySpend = toTokenUnits(monthlySpend);

  const reasons: string[] = [];

  // 1. Check duplicate invoice
  if (
    paymentPolicy.preventDuplicatePayments &&
    isDuplicate
  ) {
    reasons.push("Duplicate invoice detected.");
  }

  // 2. Check supplier registration
  if (
    paymentPolicy.requireRegisteredSupplier &&
    !verification.checks.supplierMatches
  ) {
    reasons.push("Supplier is not registered or does not match purchase order.");
  }

  // 3. Check purchase order
  if (
    !verification.checks.poExists ||
    (
      paymentPolicy.requireApprovedPurchaseOrder &&
      !verification.checks.poApproved
    )
  ) {
    reasons.push("Purchase order is missing or not approved.");
  }

  // 4. Check invoice verification
  if (
    paymentPolicy.requireExactAmountMatch &&
    !verification.checks.amountMatches
  ) {
    reasons.push("Invoice amount does not match purchase order.");
  }

  if (!verification.checks.currencyMatches) {
    reasons.push("Invoice currency does not match purchase order.");
  }

  if (
    paymentPolicy.requireRecipientMatch &&
    !verification.checks.recipientMatches
  ) {
    reasons.push("Recipient wallet does not match registered supplier.");
  }

  if (!verification.approved) {
    reasons.push(...verification.issues);
  }

  // Mandatory verification failures block payment
  if (reasons.length > 0) {
    return {
      decision: "BLOCKED",
      reasons: [...new Set(reasons)],
      amount: invoice.amount,
      monthlySpend,
    };
  }

  // 5. Check monthly spending limit
  if (
    currentMonthlySpend + amount >
    paymentPolicy.monthlySpendingLimit
  ) {
    return {
      decision: "BLOCKED",
      reasons: [
        "Monthly spending limit would be exceeded.",
      ],
      amount: invoice.amount,
      monthlySpend,
    };
  }

  // 6. Check autonomous payment limit
  if (amount > paymentPolicy.maxAutonomousPayment) {
    return {
      decision: "HUMAN_REVIEW",
      reasons: [
        "Invoice exceeds the autonomous payment limit.",
        "Human approval is required before payment.",
      ],
      amount: invoice.amount,
      monthlySpend,
    };
  }

  // 7. All checks passed
  return {
    decision: "AUTO_APPROVED",
    reasons: [
      "Invoice passed all verification checks.",
      "Payment is within autonomous spending limits.",
    ],
    amount: invoice.amount,
    monthlySpend,
  };
}