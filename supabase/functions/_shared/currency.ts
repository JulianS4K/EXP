// The currencies Exos charges in (shared by exos-checkout and the app).
//
// Every amount is handled as minor units = major x 100, so only currencies
// with two decimal places are allowed. Stripe treats zero-decimal
// currencies (JPY, KRW, ...) as whole units: a ¥3,000 ticket sent as
// 3000 x 100 would charge ¥300,000. Adding one means handling its exponent
// everywhere amounts are converted (checkout, refunds, the ledger, display).

export const CHECKOUT_CURRENCIES = [
  { code: 'USD', label: 'USD — US Dollar' },
  { code: 'EUR', label: 'EUR — Euro' },
  { code: 'GBP', label: 'GBP — British Pound' },
  { code: 'CAD', label: 'CAD — Canadian Dollar' },
  { code: 'AUD', label: 'AUD — Australian Dollar' },
  { code: 'MXN', label: 'MXN — Mexican Peso' },
  { code: 'BRL', label: 'BRL — Brazilian Real' },
] as const;

const CODES = new Set<string>(CHECKOUT_CURRENCIES.map((c) => c.code));

/** Can Exos charge in this currency (ISO 4217, any case)? */
export function isCheckoutCurrency(code: string | null | undefined): boolean {
  return CODES.has(String(code ?? '').trim().toUpperCase());
}
