// Vite HMR against the live noveo dashboard API (no Docker rebuild).
// Mutations still hit production — use for UI review only.
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const spaRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
process.env.JANUS_DASHBOARD_PROXY ??= 'https://janus.noveo.cn'

const child = spawn('npx', ['vite'], {
  cwd: spaRoot,
  stdio: 'inherit',
  shell: true,
  env: process.env,
})
child.on('exit', (code) => process.exit(code ?? 0))
