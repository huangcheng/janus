import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Served by Cowboy at /admin — keep the base path and build to dist/;
// the multi-stage Dockerfile copies dist/ into priv/www of the release.
export default defineConfig({
  plugins: [react()],
  base: '/admin/',
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
    // Dev proxy to a locally running gateway admin listener.
    proxy: {
      '/admin/api': {
        target: 'http://127.0.0.1:8090',
        changeOrigin: false,
      },
    },
  },
})
