import { parseInvoice } from "../invoice/invoice-parser";

import {
  registerInvoice,
  updateInvoiceStatus,
  getInvoiceById,
} from "../invoice/invoice-records";

import { verifyInvoice } from "./verification";

import {
  evaluatePaymentPolicy,
} from "./payment-policy";

export async function processInvoice(invoiceText: string) {

  console.log("\n========== PAYGUARD PROCESSING ==========\n");

  // STEP 1: Extract invoice information
  console.log("Step 1: Extracting invoice...");

  const invoice = await parseInvoice(invoiceText);

  console.log("Invoice extracted:", invoice.invoiceNumber);

  // STEP 2: Register invoice and detect duplicates
  console.log("\nStep 2: Registering invoice...");

  const registration = registerInvoice(invoice);

  if (!registration.success) {
    return {
      success: false,
      status: "rejected",
      paymentDecision: "BLOCKED",
      invoiceNumber: invoice.invoiceNumber,
      reasons: ["Duplicate invoice detected."],
    };
  }

  const invoiceId = registration.invoiceId!;

  // STEP 3: Verify purchase order
  console.log("\nStep 3: Verifying purchase order...");

  const verification = verifyInvoice(invoice);

  console.log("Verification:", verification);

  // STEP 4: Evaluate payment policy
  console.log("\nStep 4: Evaluating payment policy...");

  const policy = evaluatePaymentPolicy({
    invoice,
    verification,
    isDuplicate: false,
    monthlySpend: "0",
  });

  console.log("Payment decision:", policy.decision);

  // STEP 5: Update invoice status
  console.log("\nStep 5: Updating invoice status...");

  if (policy.decision === "BLOCKED") {

    updateInvoiceStatus(invoiceId, "rejected");

  } else {

    updateInvoiceStatus(invoiceId, "verified");

    if (policy.decision === "AUTO_APPROVED") {

      updateInvoiceStatus(invoiceId, "approved");

    } else {

      updateInvoiceStatus(invoiceId, "pending_approval");

    }
  }

  const savedInvoice = getInvoiceById(invoiceId);

  // STEP 6: Return complete processing result
  return {
    success: true,

    invoice: savedInvoice,

    paymentDecision: policy.decision,

    verification,

    policy,

    message:
      policy.decision === "AUTO_APPROVED"
        ? "Invoice is eligible for autonomous payment."
        : policy.decision === "HUMAN_REVIEW"
          ? "Invoice requires human approval."
          : "Invoice rejected by PayGuard.",
  };
}