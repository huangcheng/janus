// The SPA deliberately has no @types/node dependency (its app code never uses
// Node APIs), but the dev-server config is typechecked (tsconfig.node.json)
// and needs the few Node globals used there. Keep this list minimal.
declare const process: { env: Record<string, string | undefined> }
declare const __dirname: string

declare module "path" {
  const path: {
    resolve(...segments: string[]): string
  }
  export default path
}
