// Deal math, settlements and P&L for the dashboard (docs/offers-settlements.md).
// The code lives in supabase/functions/_shared/finance/ so exos-api runs the
// very same file; this module only re-exports it.

export * from '../../supabase/functions/_shared/finance/dealMath.ts';
export * from '../../supabase/functions/_shared/finance/settlementModel.ts';
export { offerPdf, settlementPdf, type OfferDoc } from '../../supabase/functions/_shared/finance/documents.ts';
