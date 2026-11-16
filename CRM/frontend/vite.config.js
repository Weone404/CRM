import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 3000,
    // ADS > Setup shows the migration SQL from ../backend/migrations (imported with ?raw)
    fs: { allow: ['..'] }
  },
  build: {
    target: 'es2020',
    // Split React out of the app code into its own long-lived, cacheable chunk.
    // App code changes far more often than React does, so returning visitors
    // re-download only the small app chunk, not the framework.
    rollupOptions: {
      output: {
        manualChunks: {
          'react-vendor': ['react', 'react-dom'],
        },
      },
    },
  }
});
