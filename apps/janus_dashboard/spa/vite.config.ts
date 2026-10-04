import path from 'path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

function rewriteCookiesForLocalDev(cookie) {
  return cookie
    .replace(/;\s*Secure/gi, '')
    .replace(/;\s*Domain=[^;]*/gi, '')
    .replace(/;\s*SameSite=None/gi, '; SameSite=Lax')
}

// Served by Cowboy at / (the dashboard owns this listener); build to dist/.
// the multi-stage Dockerfile copies dist/ into priv/www of the release.
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
    // Default: local janus-dev on :8090. Set JANUS_DASHBOARD_PROXY to
    // https://janus.noveo.cn to HMR the SPA against the live stack (no Docker rebuild).
    proxy: {
      '/api': {
        target: process.env.JANUS_DASHBOARD_PROXY || 'http://127.0.0.1:8090',
        changeOrigin: true,
        configure: (proxy) => {
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
