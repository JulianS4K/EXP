// Flat ESLint config. The former `@firebase/eslint-plugin-security-rules`
// entry (which linted firestore.rules) was removed with the Firestore→Supabase
// migration — the app no longer depends on any Firebase package. The security
// model now lives in the Supabase RLS migrations (supabase/migrations).
export default [
  {
    ignores: ['dist/**/*', 'node_modules/**/*', 'supabase/**/*'],
  },
];
