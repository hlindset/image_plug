import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vitest/config";

export default defineConfig({
  root: "demo",
  base: "/demo/",
  plugins: [svelte()],
  server: {
    host: "localhost",
    port: 5173,
    strictPort: true
  },
  build: {
    outDir: "../priv/static/demo",
    emptyOutDir: true,
    minify: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/main.js",
        assetFileNames: "assets/main[extname]"
      }
    }
  },
  test: {
    include: ["src/**/*.test.ts"]
  }
});
