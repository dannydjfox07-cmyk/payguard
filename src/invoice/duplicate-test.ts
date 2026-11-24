import { registerInvoice } from "./invoice-records";
import type { Invoice } from "./invoice-types";

const sampleInvoice: Invoice = {
  supplier: "Acme Software Ltd",
  invoiceNumber: "INV-2026-001",
  poNumber: "PO-2026-0042",
  amount: "250",
  currency: "tUSD8",
  recipient: "0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806",
  description: "Software development services",
  dueDate: "November 30, 2026",
};

function main() {
  console.log("First submission:");

  const first = registerInvoice(sampleInvoice);
  console.log(first);

  console.log("\nSecond submission:");

  const second = registerInvoice(sampleInvoice);
  console.log(second);
}

main();