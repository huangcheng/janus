/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_TURNSTILE_SITEKEY?: string
  readonly VITE_FLAG_MODEL_PRICES?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
