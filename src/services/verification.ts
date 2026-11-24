import type { Invoice } from "../invoice/invoice-types";
import { purchaseOrders } from "../invoice/purchase-orders";

export interface VerificationResult {
  approved: boolean;
  poNumber: string;
  checks: {
    poExists: boolean;
    supplierMatches: boolean;
    amountMatches: boolean;
    currencyMatches: boolean;
    recipientMatches: boolean;
    poApproved: boolean;
  };
  issues: string[];
}

export function verifyInvoice(invoice: Invoice): VerificationResult {
  const po = purchaseOrders.find(
    (order) => order.poNumber === invoice.poNumber,
  );

  const checks = {
    poExists: !!po,
    supplierMatches: false,
    amountMatches: false,
    currencyMatches: false,
    recipientMatches: false,
    poApproved: false,
  };

  const issues: string[] = [];

  if (!po) {
    issues.push("Purchase order does not exist.");

    return {
      approved: false,
      poNumber: invoice.poNumber,
      checks,
      issues,
    };
  }

  checks.supplierMatches =
    invoice.supplier.trim().toLowerCase() ===
    po.supplier.trim().toLowerCase();

  checks.amountMatches =
    invoice.amount === po.approvedAmount;

  checks.currencyMatches =
    invoice.currency === po.currency;

  checks.recipientMatches =
    invoice.recipient.toLowerCase() ===
    po.recipient.toLowerCase();

  checks.poApproved = po.status === "approved";

  if (!checks.supplierMatches) {
    issues.push("Supplier does not match purchase order.");
  }

  if (!checks.amountMatches) {
    issues.push("Invoice amount differs from approved purchase order.");
  }

  if (!checks.currencyMatches) {
    issues.push("Invoice currency does not match purchase order.");
  }

  if (!checks.recipientMatches) {
    issues.push("Payment wallet does not match registered supplier wallet.");
  }

  if (!checks.poApproved) {
    issues.push("Purchase order is not approved.");
  }

  const approved = Object.values(checks).every(Boolean);

  return {
    approved,
    poNumber: invoice.poNumber,
    checks,
    issues,
  };
}