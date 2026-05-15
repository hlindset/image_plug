export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type OutputFormat = "auto" | "webp" | "avif" | "jpeg" | "png";
export type Signature = "_" | "unsafe";
export type SourceImage = "images/dog.jpg" | "images/cat-300.jpg";

export type DemoState = {
  signature: Signature;
  source: SourceImage;
  resizeEnabled: boolean;
  resizeMode: ResizeMode;
  width: number;
  height: number;
  gravity: Gravity;
  enlarge: boolean;
  cropEnabled: boolean;
  cropWidth: number;
  cropHeight: number;
  format: OutputFormat;
  quality: number;
};

export type ProcessedImageMetadata = {
  width: number;
  height: number;
  bytes: number | null;
};

export const defaultDemoState: DemoState = {
  signature: "_",
  source: "images/dog.jpg",
  resizeEnabled: true,
  resizeMode: "fill",
  width: 640,
  height: 360,
  gravity: "ce",
  enlarge: false,
  cropEnabled: false,
  cropWidth: 640,
  cropHeight: 420,
  format: "auto",
  quality: 85
};

export function optionSegments(currentState: DemoState): string[] {
  const segments: string[] = [];

  if (currentState.cropEnabled) {
    segments.push(`c:${currentState.cropWidth}:${currentState.cropHeight}`);
  }

  if (currentState.resizeEnabled) {
    segments.push(
      [
        "rs",
        currentState.resizeMode,
        currentState.width,
        currentState.height,
        currentState.enlarge ? 1 : 0
      ].join(":"),
      `g:${currentState.gravity}`
    );
  }

  if (currentState.format !== "auto") {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.quality > 0) {
    segments.push(`q:${currentState.quality}`);
  }

  return segments;
}

export function resolvedOutputLabel(currentState: DemoState): string {
  if (currentState.format === "auto") {
    return "auto -> webp";
  }

  return currentState.format;
}

export function processedSizeLabel(metadata: ProcessedImageMetadata | null): string {
  if (metadata === null) {
    return "Loading";
  }

  const dimensions = `${metadata.width} × ${metadata.height}`;

  if (metadata.bytes === null) {
    return dimensions;
  }

  const kilobytes = Math.max(1, Math.round(metadata.bytes / 1024));

  return `${dimensions} (${kilobytes} kB)`;
}

export function buildProcessingPath(currentState: DemoState): string {
  const options = optionSegments(currentState).join("/");

  return `/${currentState.signature}/${options}/plain/${currentState.source}`;
}
