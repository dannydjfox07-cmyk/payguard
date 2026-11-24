import { z } from "zod";

export const InvoiceSchema = z.object({
  supplier: z.string().min(1),
  invoiceNumber: z.string().min(1),
  poNumber: z.string().min(1),

  amount: z.string().regex(/^\d+(\.\d+)?$/),
  currency: z.enum(["tUSD8"]),

  recipient: z.string().regex(/^0x[a-fA-F0-9]{40}$/),

  description: z.string().min(1),
  dueDate: z.string(),
});

export type Invoice = z.infer<typeof InvoiceSchema>;