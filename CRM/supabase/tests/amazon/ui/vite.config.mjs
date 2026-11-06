import { createRequire } from 'module';
import path from 'path';
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FE = path.resolve(__dirname, '../../../../frontend');
const req = createRequire(path.join(FE, 'package.json'));
const react = req('@vitejs/plugin-react').default;
export default {
  root: __dirname,
  plugins: [react()],
  resolve: { alias: {
    react: path.join(FE, 'node_modules/react'), 'react-dom': path.join(FE, 'node_modules/react-dom'),
    '@supabase/supabase-js': path.join(FE, 'node_modules/@supabase/supabase-js'),
  } },
  css: { postcss: { plugins: [req('tailwindcss')({ config: path.join(FE, 'tailwind.config.js') }), req('autoprefixer')] } },
  server: { port: 5199, strictPort: true, fs: { allow: [path.resolve(__dirname, '../../../..')] } },
  define: { 'import.meta.env.VITE_SUPABASE_URL': JSON.stringify('http://localhost:54399'),
            'import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY': JSON.stringify('test-anon-key'),
            'import.meta.env.VITE_BACKEND': JSON.stringify('supabase') },
};
