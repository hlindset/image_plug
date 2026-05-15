export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type OutputFormat = "auto" | "webp" | "avif" | "jpeg" | "png";
export type Signature = "_" | "unsafe";
export type SourceImage = "images/dog.jpg" | "images/cat-300.jpg";

export type DemoState = {
  signature: Signature;
  source: SourceImage;
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

export const defaultDemoState: DemoState = {
  signature: "_",
  source: "images/dog.jpg",
  resizeMode: "fill",
  width: 1160,
  height: 540,
  gravity: "ce",
  enlarge: false,
  cropEnabled: false,
  cropWidth: 640,
  cropHeight: 420,
  format: "webp",
  quality: 82
};

export function optionSegments(currentState: DemoState): string[] {
  const resize = [
    "rs",
    currentState.resizeMode,
    currentState.width,
    currentState.height,
    currentState.enlarge ? 1 : 0
  ].join(":");

  const segments = [resize, `g:${currentState.gravity}`];

  if (currentState.cropEnabled) {
    segments.unshift(`c:${currentState.cropWidth}:${currentState.cropHeight}`);
  }

  if (currentState.format !== "auto") {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.quality > 0) {
    segments.push(`q:${currentState.quality}`);
  }

  return segments;
}

export function buildProcessingPath(currentState: DemoState): string {
  const options = optionSegments(currentState).join("/");

  return `/${currentState.signature}/${options}/plain/${currentState.source}`;
}
