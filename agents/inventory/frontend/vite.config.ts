import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  base: '/static/',
  build: {
    // The reference drop's layout had the Go code in backend/, and this path came with it - which
    // meant `npm run build` wrote its output next to a directory that does not exist here, and the
    // Dockerfile's COPY --from=frontend-builder /app/backend_go/static failed with "not found" at the
    // last stage, after both expensive stages had succeeded. The server looks for static/ beside the
    // binary and at /app/static; both are reached from here.
    outDir: '../backend_go/static',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
})