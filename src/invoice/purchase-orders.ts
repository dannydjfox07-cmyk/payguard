export interface PurchaseOrder {
  poNumber: string;
  supplier: string;
  approvedAmount: string;
  currency: string;
  recipient: string;
  description: string;
  status: "approved" | "cancelled" | "completed";
}

export const purchaseOrders: PurchaseOrder[] = [
  {
    poNumber: "PO-2026-0042",
    supplier: "Acme Software Ltd",
    approvedAmount: "250",
    currency: "tUSD8",
    recipient: "0xf3f0F1d3a5A49425Fd5fb62ff7b2198e755dE806",
    description: "Software development services",
    status: "approved",
  },
];