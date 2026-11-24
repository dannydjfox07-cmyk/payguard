import { evaluatePaymentPolicy } from "./payment-policy";

import type { Invoice } from "../invoice/invoice-types";
import type { VerificationResult } from "./verification";

const sampleInvoice: Invoice = {
  supplier: "Acme Software Ltd",
  invoiceNumber: "INV-2026-001",
  poNumber: "PO-2026-0042",
  amount: "0.25",
  currency: "tUSD8",
  recipient: "0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806",
  description: "Software development services",
  dueDate: "November 30, 2026",
};

const successfulVerification: VerificationResult = {
  approved: true,
  poNumber: "PO-2026-0042",

  checks: {
    poExists: true,
    supplierMatches: true,
    amountMatches: true,
    currencyMatches: true,
    recipientMatches: true,
    poApproved: true,
  },

  issues: [],
};

function runTest(
  name: string,
  amount: string,
  isDuplicate: boolean,
  monthlySpend: string,
  verification = successfulVerification,
) {
  const result = evaluatePaymentPolicy({
    invoice: {
      ...sampleInvoice,
      amount,
    },

    verification,
    isDuplicate,
    monthlySpend,
  });

  console.log(`\n${name}`);
  console.log(JSON.stringify(result, null, 2));
}

function main() {

  // Test A: Small valid invoice
  runTest(
    "TEST A: Autonomous payment",
    "0.25",
    false,
    "0",
  );

  // Test B: Exceeds autonomous limit
  runTest(
    "TEST B: Human approval required",
    "2",
    false,
    "0",
  );

  // Test C: Duplicate invoice
  runTest(
    "TEST C: Duplicate invoice",
    "0.25",
    true,
    "0",
  );

  // Test D: Monthly limit exceeded
  runTest(
    "TEST D: Monthly spending limit",
    "0.5",
    false,
    "4.8",
  );

  // Test E: Recipient mismatch
  const badVerification: VerificationResult = {
    ...successfulVerification,

    approved: false,

    checks: {
      ...successfulVerification.checks,
      recipientMatches: false,
    },

    issues: [
      "Payment wallet does not match registered supplier wallet.",
    ],
  };

  runTest(
    "TEST E: Incorrect recipient",
    "0.25",
    false,
    "0",
    badVerification,
  );
}

main();