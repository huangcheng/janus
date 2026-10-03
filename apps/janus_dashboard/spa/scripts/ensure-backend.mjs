// Ensures the janus-dev backend container is running before `npm run dev`.
// One command = full dev loop: backend container + Vite HMR on :3000.
import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'

const NAME = 'janus-dev'
const IMAGE = 'janus:dashboard'

const run = (cmd, args, opts = {}) =>
  spawnSync(cmd, args, { encoding: 'utf8', ...opts })

function running() {
  const r = run('docker', ['ps', '--filter', `name=^/${NAME}$`, '--filter', 'status=running', '--format', '{{.Names}}'])
  return r.status === 0 && r.stdout.trim() === NAME
}

function exists() {
  const r = run('docker', ['ps', '-a', '--filter', `name=^/${NAME}$`, '--format', '{{.Names}}'])
  return r.status === 0 && r.stdout.trim() === NAME
}

if (running()) {
  console.log(`backend: ${NAME} already running`)
} else if (exists()) {
  console.log(`backend: starting existing ${NAME} …`)
  run('docker', ['start', NAME], { stdio: 'inherit' })
} else {
  const b64 = randomBytes(32).toString('base64')
  console.log(`backend: creating ${NAME} from ${IMAGE} …`)
  const r = run('docker', [
    'run', '-d', '--name', NAME,
    '-p', '127.0.0.1:8080:8080', '-p', '127.0.0.1:8090:8090',
    '-e', `JANUS_SECRETS_KEY=k1:${b64}`,
    '-e', 'JANUS_API_KEY_PEPPER=dev-pepper',
    '-e', 'JANUS_DASHBOARD_PASSWORD=dev',
    IMAGE,
  ], { stdio: 'inherit' })
  if (r.status !== 0) {
    console.error('failed to start backend; is the janus:dashboard image built? (docker build -t janus:dashboard .)')
    process.exit(1)
  }
}
console.log('backend ready: data 127.0.0.1:8080 · dashboard api 127.0.0.1:8090 (password: dev)')
