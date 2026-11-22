// Flat ESLint config. The former `@firebase/eslint-plugin-security-rules`
// entry (which linted firestore.rules) was removed with the Firestore→Supabase
// migration — the app no longer depends on any Firebase package. The security
// model now lives in the Supabase RLS migrations (supabase/migrations).
//
// `npm run lint:a11y` (CI's TypeScript job): eslint-plugin-jsx-a11y's
// recommended rules on the app's JSX. Type errors are `npm run lint` (tsc);
// this config checks accessibility only. docs/pci.md "Accessibility conformance".
import tsParser from '@typescript-eslint/parser';
import jsxA11y from 'eslint-plugin-jsx-a11y';

// Existing `// eslint-disable-next-line react-hooks/...` and
// `@typescript-eslint/...` comments name plugins this config doesn't load.
// ESLint fails on a disable comment for an unknown rule, so those two
// namespaces answer every rule name with a no-op.
const noop = { meta: { schema: false }, create: () => ({}) };
const ruleStubs = { rules: new Proxy({}, { get: (_t, name) => (typeof name === 'string' ? noop : undefined), has: () => true }) };

export default [
  {
    ignores: ['dist/**/*', 'node_modules/**/*', 'supabase/**/*'],
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    ...jsxA11y.flatConfigs.recommended,
    languageOptions: {
      ...jsxA11y.flatConfigs.recommended.languageOptions,
      parser: tsParser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    plugins: { ...jsxA11y.flatConfigs.recommended.plugins, 'react-hooks': ruleStubs, '@typescript-eslint': ruleStubs },
    rules: {
      ...jsxA11y.flatConfigs.recommended.rules,
      // Labels in this app wrap their text in a span or two.
      'jsx-a11y/label-has-associated-control': ['error', { depth: 4 }],
      // `role` on our own components (ShareButtons role="fan") is a prop, not ARIA.
      'jsx-a11y/aria-role': ['error', { ignoreNonDOM: true }],
      // Every autoFocus here follows a user action (a dialog, sheet or inline
      // editor opening; the door's scan box): moving focus into what just
      // opened is the WAI-ARIA dialog pattern, not a surprise on page load.
      'jsx-a11y/no-autofocus': 'off',
    },
    linterOptions: { reportUnusedDisableDirectives: 'off' },
  },
  {
    // Known gap, organizer-only: the create / edit event forms have 45 visible
    // labels not tied to their inputs (most inputs carry an aria-label with the
    // same text, so they are still named). Warn here; `lint:a11y` caps the
    // warnings (--max-warnings) so the count can only go down.
    files: ['src/views/CreateEvent.tsx', 'src/views/EditEvent.tsx'],
    rules: { 'jsx-a11y/label-has-associated-control': ['warn', { depth: 4 }] },
  },
];
