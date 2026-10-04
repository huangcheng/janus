// Vite HMR against a local Janus dashboard on :8090 (no Docker, no noveo).
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const spaRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
process.env.JANUS_DASHBOARD_PROXY = 'http://127.0.0.1:8090'

const child = spawn('npx', ['vite'], {
  cwd: spaRoot,
  stdio: 'inherit',
  shell: true,
  env: process.env,
})
child.on('exit', (code) => process.exit(code ?? 0))
