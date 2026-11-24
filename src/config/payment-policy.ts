import { parseUnits } from "viem";

export const paymentPolicy = {
  currency: "tUSD8",

  // Maximum amount PayGuard can pay without human approval
  maxAutonomousPayment: parseUnits("1", 6),

  // Maximum total autonomous spending per month
  monthlySpendingLimit: parseUnits("5", 6),

  requireRegisteredSupplier: true,
  requireApprovedPurchaseOrder: true,
  requireExactAmountMatch: true,
  requireRecipientMatch: true,
  preventDuplicatePayments: true,
};