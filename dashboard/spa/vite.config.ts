import path from 'path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

function rewriteCookiesForLocalDev(cookie: string): string {
  return cookie
    .replace(/;\s*Secure/gi, '')
    .replace(/;\s*Domain=[^;]*/gi, '')
    .replace(/;\s*SameSite=None/gi, '; SameSite=Lax')
}

// The FastAPI dashboard backend serves the built SPA from dist/ in
// production; in dev, vite serves the SPA and proxies /api to it.
const proxyTarget = process.env.JANUS_DASHBOARD_PROXY || 'http://127.0.0.1:8091'

// Auto-login is opt-in: JANUS_DASHBOARD_PASSWORD in the env alone must not
// silently mint an admin session for every browser on the dev server.
const autoLogin = process.env.JANUS_DEV_AUTO_LOGIN === '1'

function isLoopback(target: string): boolean {
  try {
    const host = new URL(target).hostname
    return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]'
  } catch {
    return false
  }
}

// Dev convenience for an already-configured password-only account. Setup,
// TOTP, and passkey-only accounts always require manual sign-in. The minted
// JWT is injected into proxied /api requests; neither secret is ever logged.
async function loginForDevToken(): Promise<string> {
  if (!autoLogin) return ''
  const password = process.env.JANUS_DASHBOARD_PASSWORD
  if (!password) {
    console.warn('[dev] JANUS_DEV_AUTO_LOGIN=1 but JANUS_DASHBOARD_PASSWORD is unset — not logging in')
    return ''
  }
  try {
    const statusResponse = await fetch(`${proxyTarget}/api/auth/status`)
    if (!statusResponse.ok) {
      console.warn(`[dev] auto-login could not read account status: HTTP ${statusResponse.status}`)
      return ''
    }
    const status = (await statusResponse.json()) as {
      configured?: boolean
      username?: string
      has_password?: boolean
      has_totp?: boolean
    }
    if (!status.configured || !status.username || !status.has_password || status.has_totp) {
      console.warn('[dev] auto-login requires a configured password-only account; sign in manually on :3000')
      return ''
    }
    const res = await fetch(`${proxyTarget}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: status.username, password }),
    })
    if (!res.ok) {
      console.warn(`[dev] auto-login failed: HTTP ${res.status} from ${proxyTarget} — sign in manually on :3000`)
      return ''
    }
    const data = (await res.json()) as { token?: string }
    return data.token ?? ''
  } catch (err) {
    console.warn(
      `[dev] auto-login failed against ${proxyTarget}: ${
        err instanceof Error ? err.message : String(err)
      }`,
    )
    return ''
  }
}

const devToken = await loginForDevToken()
if (!isLoopback(proxyTarget)) {
  console.warn(
    `[dev] proxying /api to non-loopback ${proxyTarget}: proxied cookies lose Secure/Domain/SameSite` +
      (devToken ? ' and every proxied /api request carries an injected admin JWT' : '') +
      ' — use this only on a trusted machine.',
  )
}
if (devToken) {
  console.warn(
    `[dev] auto-login active for ${proxyTarget}: injected JWT belongs to the operator account; do not share this dev server.`,
  )
}

export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: '/',
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    // Windows often reserves the 5xxx range (Hyper-V); pin a stable port.
    host: '127.0.0.1',
    port: 3000,
    strictPort: true,
    // Default: local dashboard backend on :8091. Set JANUS_DASHBOARD_PROXY to
    // https://your-gateway.example to HMR the SPA against the live stack.
    proxy: {
      '/api': {
        target: proxyTarget,
        changeOrigin: true,
        configure: (proxy) => {
          if (devToken) {
            proxy.on('proxyReq', (proxyReq) => {
              proxyReq.setHeader('authorization', `Bearer ${devToken}`)
            })
          }
          proxy.on('proxyRes', (proxyRes) => {
            const cookies = proxyRes.headers['set-cookie']
            if (cookies) {
              proxyRes.headers['set-cookie'] = cookies.map(rewriteCookiesForLocalDev)
            }
          })
        },
      },
    },
  },
})
