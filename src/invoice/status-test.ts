import {
  registerInvoice,
  getInvoiceById,
  updateInvoiceStatus,
  markInvoicePaid,
} from "./invoice-records";

import type { Invoice } from "./invoice-types";

const sampleInvoice: Invoice = {
  supplier: "Acme Software Ltd",
  invoiceNumber: `INV-STATUS-${Date.now()}`,
  poNumber: "PO-2026-0042",
  amount: "250",
  currency: "tUSD8",
  recipient: "0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806",
  description: "Software development services",
  dueDate: "November 30, 2026",
};

function main() {
  console.log("Step 1: Register invoice");

  const registration = registerInvoice(sampleInvoice);

  if (!registration.success || !registration.invoiceId) {
    throw new Error("Could not register test invoice.");
  }

  const id = registration.invoiceId;

  console.log(registration);

  console.log("\nStep 2: Mark invoice as verified");

  updateInvoiceStatus(id, "verified");

  console.log(getInvoiceById(id));

  console.log("\nStep 3: Approve invoice");

  updateInvoiceStatus(id, "approved");

  console.log(getInvoiceById(id));

  console.log("\nStep 4: Simulate successful payment");

  const paidInvoice = markInvoicePaid(
    id,
    "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  );

  console.log(paidInvoice);

  console.log("\nPayGuard invoice lifecycle completed!");
}

main();