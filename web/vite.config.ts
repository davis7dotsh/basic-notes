import { defineConfig } from 'vite'

// Output goes straight into the app bundle's resources. Served inside WKWebView via nbm://app/
export default defineConfig({
  base: './',
  build: {
    outDir: '../App/Resources/Web',
    emptyOutDir: true,
    target: 'safari18',
    sourcemap: false,
    chunkSizeWarningLimit: 4000,
  },
  server: { host: '0.0.0.0', port: 5193 },
})
