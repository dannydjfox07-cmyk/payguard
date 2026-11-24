import { parseInvoice } from "./invoice-parser";

const sampleInvoice = `
INVOICE

Supplier: Acme Software Ltd
Invoice Number: INV-2026-001
Purchase Order: PO-2026-0042

Description: Software development services

Amount: 250 tUSD8

Payment Wallet:
0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806

Due Date: November 30, 2026
`;

async function main() {
  console.log("Reading invoice...\n");

  const invoice = await parseInvoice(sampleInvoice);

  console.log("Extracted invoice:");
  console.log(JSON.stringify(invoice, null, 2));
}

main().catch(console.error);