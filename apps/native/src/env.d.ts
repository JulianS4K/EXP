// The SPA files this shell compiles against read import.meta.env (Vite).
interface ImportMeta {
  readonly env: Record<string, string | undefined>;
}
