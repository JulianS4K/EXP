import { CHECKOUT_CURRENCIES, isCheckoutCurrency } from '../lib/currency';

// The one currency picker for Create and Edit, so the two can't drift. Options
// come from the shared checkout list (lib/currency.ts, one copy with
// exos-checkout). An event already saved in a code outside that list keeps it
// as an extra option rather than being silently switched.
export default function CurrencySelect({
  id,
  value,
  onChange,
  className,
}: {
  id: string;
  value: string | undefined;
  onChange: (code: string) => void;
  className: string;
}) {
  const current = (value || 'USD').toUpperCase();
  return (
    <select id={id} className={className} value={current} onChange={(e) => onChange(e.target.value)}>
      {CHECKOUT_CURRENCIES.map(({ code, label }) => (
        <option key={code} value={code}>{label}</option>
      ))}
      {!isCheckoutCurrency(current) && <option value={current}>{current}</option>}
    </select>
  );
}
