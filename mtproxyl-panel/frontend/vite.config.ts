import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  base: './',
  plugins: [react()],
  define: {
    // @iarna/toml references Node's `global`, which is absent in the browser.
    global: 'globalThis',
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      // ws:true forwards the dashboard's /api/ws WebSocket upgrade too.
      '/api': { target: 'http://localhost:8080', ws: true },
    },
  },
})
