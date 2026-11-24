import { processInvoice } from "./invoice-processor";

const sampleInvoice = `
INVOICE

Supplier: Acme Software Ltd

Invoice Number: INV-PIPELINE-006

Purchase Order: PO-2026-0042

Description: Software development services

Amount: 1.25 tUSD8

Recepient Wallet:
0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806

Due Date: November 30, 2026
`;

async function main() {

  const result = await processInvoice(sampleInvoice);

  console.log("\n========== FINAL RESULT ==========\n");

  console.log(JSON.stringify(result, null, 2));

}

main().catch(console.error);