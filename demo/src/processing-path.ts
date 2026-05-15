export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type CropGravity = "inherit" | Gravity;
export type OutputFormat = "webp" | "avif" | "jpeg" | "png";
export type Flip = "none" | "horizontal" | "vertical" | "both";
export type CanvasMode = "extend" | "aspectRatio";
export type Signature = "_" | "unsafe";
export type SourceImage = "images/dog.jpg" | "images/cat-300.jpg";

export type DemoState = {
  signature: Signature;
  source: SourceImage;
  autoRotateEnabled: boolean;
  flip: Flip;
  resizeEnabled: boolean;
  resizeMode: ResizeMode;
  width: number;
  height: number;
  zoomEnabled: boolean;
  zoom: number;
  dprEnabled: boolean;
  dpr: number;
  minWidthEnabled: boolean;
  minWidth: number;
  minHeightEnabled: boolean;
  minHeight: number;
  canvasEnabled: boolean;
  canvasMode: CanvasMode;
  extendAspectWidth: number;
  extendAspectHeight: number;
  gravityEnabled: boolean;
  gravity: Gravity;
  enlarge: boolean;
  cropEnabled: boolean;
  cropWidth: number;
  cropHeight: number;
  cropGravity: CropGravity;
  formatEnabled: boolean;
  format: OutputFormat;
  qualityEnabled: boolean;
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
  autoRotateEnabled: false,
  flip: "none",
  resizeEnabled: false,
  resizeMode: "fill",
  width: 640,
  height: 360,
  zoomEnabled: false,
  zoom: 1.5,
  dprEnabled: false,
  dpr: 2,
  minWidthEnabled: false,
  minWidth: 320,
  minHeightEnabled: false,
  minHeight: 180,
  canvasEnabled: false,
  canvasMode: "extend",
  extendAspectWidth: 16,
  extendAspectHeight: 9,
  gravityEnabled: false,
  gravity: "ce",
  enlarge: false,
  cropEnabled: false,
  cropWidth: 640,
  cropHeight: 420,
  cropGravity: "inherit",
  formatEnabled: false,
  format: "jpeg",
  qualityEnabled: false,
  quality: 85
};

export function optionSegments(currentState: DemoState): string[] {
  const segments: string[] = [];

  if (currentState.autoRotateEnabled) {
    segments.push("ar:1");
  }

  if (currentState.flip === "horizontal") {
    segments.push("fl:1");
  }

  if (currentState.flip === "vertical") {
    segments.push("fl:0:1");
  }

  if (currentState.flip === "both") {
    segments.push("fl");
  }

  if (currentState.cropEnabled) {
    const cropSegment = ["c", currentState.cropWidth, currentState.cropHeight];

    if (currentState.cropGravity !== "inherit") {
      cropSegment.push(currentState.cropGravity);
    }

    segments.push(cropSegment.join(":"));
  }

  if (currentState.resizeEnabled) {
    segments.push(
      [
        "rs",
        currentState.resizeMode,
        currentState.width,
        currentState.height,
        currentState.enlarge ? 1 : 0
      ].join(":")
    );

    if (currentState.zoomEnabled) {
      segments.push(`z:${currentState.zoom}`);
    }

    if (currentState.dprEnabled) {
      segments.push(`dpr:${currentState.dpr}`);
    }

    if (currentState.minWidthEnabled) {
      segments.push(`mw:${currentState.minWidth}`);
    }

    if (currentState.minHeightEnabled) {
      segments.push(`mh:${currentState.minHeight}`);
    }
  }

  if (currentState.canvasEnabled && currentState.canvasMode === "extend") {
    segments.push("ex:1");
  }

  if (currentState.canvasEnabled && currentState.canvasMode === "aspectRatio") {
    segments.push(`exar:${currentState.extendAspectWidth}:${currentState.extendAspectHeight}`);
  }

  if (
    currentState.gravityEnabled &&
    (currentState.resizeEnabled || (currentState.cropEnabled && currentState.cropGravity === "inherit"))
  ) {
    segments.push(`g:${currentState.gravity}`);
  }

  if (currentState.formatEnabled) {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.qualityEnabled) {
    segments.push(`q:${currentState.quality}`);
  }

  return segments;
}

export function resolvedOutputLabel(currentState: DemoState): string {
  if (!currentState.formatEnabled) {
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
  const optionsPath = options === "" ? "" : `/${options}`;

  return `/${currentState.signature}${optionsPath}/plain/${currentState.source}`;
}
