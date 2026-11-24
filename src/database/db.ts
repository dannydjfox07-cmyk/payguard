import { Database } from "bun:sqlite";

export const db = new Database("payguard.db");

db.run("PRAGMA journal_mode = WAL");

db.run(`
  CREATE TABLE IF NOT EXISTS invoices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    supplier TEXT NOT NULL,
    invoice_number TEXT NOT NULL,
    po_number TEXT NOT NULL,

    amount TEXT NOT NULL,
    currency TEXT NOT NULL,
    recipient TEXT NOT NULL,

    description TEXT,
    due_date TEXT,

    status TEXT NOT NULL DEFAULT 'received',

    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(supplier, invoice_number)
  )
`);

// Check whether tx_hash column already exists
const columns = db.query("PRAGMA table_info(invoices)").all() as {
  name: string;
}[];

const hasTxHash = columns.some(
  (column) => column.name === "tx_hash"
);

// Add tx_hash if it doesn't exist
if (!hasTxHash) {
  db.run(`
    ALTER TABLE invoices
    ADD COLUMN tx_hash TEXT
  `);
}