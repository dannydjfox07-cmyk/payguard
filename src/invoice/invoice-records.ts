import { db } from "../database/db";
import type { Invoice } from "./invoice-types";

export function registerInvoice(invoice: Invoice) {
  const result = db.query(`
    INSERT OR IGNORE INTO invoices (
      supplier,
      invoice_number,
      po_number,
      amount,
      currency,
      recipient,
      description,
      due_date
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    invoice.supplier.trim(),
    invoice.invoiceNumber.trim(),
    invoice.poNumber.trim(),
    invoice.amount,
    invoice.currency,
    invoice.recipient,
    invoice.description,
    invoice.dueDate,
  );

  if (result.changes === 0) {
    return {
      success: false,
      duplicate: true,
      message: "This invoice has already been registered.",
    };
  }

  return {
    success: true,
    duplicate: false,
    invoiceId: Number(result.lastInsertRowid),
    message: "Invoice successfully registered.",
  };
}

export type InvoiceStatus =
  | "received"
  | "needs_review"
  | "verified"
  | "approved"
  | "paid"
  | "rejected";

export interface InvoiceRecord {
  id: number;
  supplier: string;
  invoice_number: string;
  po_number: string;
  amount: string;
  currency: string;
  recipient: string;
  description: string | null;
  due_date: string | null;
  status: InvoiceStatus;
  tx_hash: string | null;
  created_at: string;
  updated_at: string;
}

// Retrieve invoice by database ID
export function getInvoiceById(id: number) {
  return db.query(`
    SELECT * FROM invoices
    WHERE id = ?
  `).get(id) as InvoiceRecord | null;
}

// Retrieve invoices by status
export function getInvoicesByStatus(status: InvoiceStatus) {
  return db.query(`
    SELECT * FROM invoices
    WHERE status = ?
    ORDER BY created_at DESC
  `).all(status) as InvoiceRecord[];
}

// Update invoice status with transition rules
export function updateInvoiceStatus(
  id: number,
  newStatus: InvoiceStatus
) {
  const invoice = getInvoiceById(id);

  if (!invoice) {
    throw new Error("Invoice not found.");
  }

  const allowedTransitions: Record<
    InvoiceStatus,
    InvoiceStatus[]
  > = {
    received: ["needs_review", "verified", "rejected"],
    needs_review: ["verified", "rejected"],
    verified: ["approved", "rejected"],
    approved: ["paid"],
    paid: [],
    rejected: [],
  };

  const allowed = allowedTransitions[invoice.status];

  if (!allowed.includes(newStatus)) {
    throw new Error(
      `Cannot change invoice status from ${invoice.status} to ${newStatus}`
    );
  }

  db.query(`
    UPDATE invoices
    SET status = ?,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ?
  `).run(newStatus, id);

  return getInvoiceById(id);
}

// Mark invoice as paid after successful blockchain transaction
export function markInvoicePaid(
  id: number,
  transactionHash: string
) {
  const invoice = getInvoiceById(id);

  if (!invoice) {
    throw new Error("Invoice not found.");
  }

  if (invoice.status !== "approved") {
    throw new Error(
      "Only approved invoices can be marked as paid."
    );
  }

  const update = db.query(`
    UPDATE invoices
    SET status = 'paid',
        tx_hash = ?,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ?
      AND status = 'approved'
  `).run(transactionHash, id);

  if (update.changes !== 1) {
    throw new Error("Invoice payment status update failed.");
  }

  return getInvoiceById(id);
}