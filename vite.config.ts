import { svelte } from "@sveltejs/vite-plugin-svelte";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { imageSize } from "image-size";
import { transformWithOxc, type Plugin } from "vite";

const currentDirectory = dirname(fileURLToPath(import.meta.url));
const sampleImagesModuleId = "virtual:sample-images";
const resolvedSampleImagesModuleId = `\0${sampleImagesModuleId}.ts`;
const sampleImageExtensions = new Set([".avif", ".jpeg", ".jpg", ".png", ".webp"]);
const maxDemoOriginBytes = 10_000_000;
const maxDemoInputPixels = 40_000_000;

function sampleImagesPlugin(
  imagesDirectory = resolve(currentDirectory, "priv/static/images"),
): Plugin {
  return {
    name: "sample-images",
    resolveId(id) {
      if (id === sampleImagesModuleId) {
        return resolvedSampleImagesModuleId;
      }

      return null;
    },
    async load(id) {
      if (id === resolvedSampleImagesModuleId) {
        const transformed = await transformWithOxc(
          buildSampleImagesModule(imagesDirectory),
          "sample-images.ts",
        );

        return transformed.code;
      }

      return null;
    },
    configureServer(server) {
      server.watcher.add(imagesDirectory);
      server.watcher.on("all", (_event, changedPath) => {
        if (relative(imagesDirectory, changedPath).startsWith("..")) {
          return;
        }

        const sampleImagesModule = server.moduleGraph.getModuleById(resolvedSampleImagesModuleId);

        if (sampleImagesModule !== undefined) {
          server.moduleGraph.invalidateModule(sampleImagesModule);
          server.ws.send({ type: "full-reload" });
        }
      });
    },
  };
}

function buildSampleImagesModule(imagesDirectory: string): string {
  const sampleImages = readdirSync(imagesDirectory)
    .filter((fileName) => sampleImageExtensions.has(fileExtension(fileName)))
    .sort((left, right) => left.localeCompare(right))
    .flatMap((fileName) => {
      const filePath = join(imagesDirectory, fileName);
      const dimensions = imageSize(readFileSync(filePath));

      if (dimensions.width === undefined || dimensions.height === undefined) {
        throw new Error(`Could not read image dimensions for ${filePath}`);
      }

      if (
        statSync(filePath).size > maxDemoOriginBytes ||
        dimensions.width * dimensions.height > maxDemoInputPixels
      ) {
        return [];
      }

      return [
        {
          path: `images/${encodeURIComponent(fileName)}`,
          label: fileName,
          width: dimensions.width,
          height: dimensions.height,
        },
      ];
    });

  return `export const sampleImages = ${JSON.stringify(sampleImages, null, 2)} as const;\n`;
}

function fileExtension(fileName: string): string {
  const lastDotIndex = fileName.lastIndexOf(".");

  if (lastDotIndex === -1) {
    return "";
  }

  return fileName.slice(lastDotIndex).toLowerCase();
}

export default defineConfig({
  root: "demo",
  base: "/demo/",
  plugins: [sampleImagesPlugin(), svelte()],
  server: {
    host: "localhost",
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: "../priv/static/demo",
    emptyOutDir: true,
    minify: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/main.js",
        assetFileNames: "assets/main[extname]",
      },
    },
  },
  test: {
    include: ["src/**/*.test.ts"],
  },
});
