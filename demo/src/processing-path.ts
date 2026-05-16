export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type GravityMode = "anchor" | "focalPoint" | "offset";
export type CropGravity = "inherit" | Gravity;
export type OutputFormat = "webp" | "avif" | "jpeg" | "png";
export type Flip = "none" | "horizontal" | "vertical" | "both";
export type Rotate = 0 | 90 | 180 | 270;
export type CanvasMode = "extend" | "aspectRatio";
export type Signature = "_" | "unsafe";
export type SourceImage = "images/dog.jpg" | "images/cat-300.jpg";

export type DemoState = {
  signature: Signature;
  source: SourceImage;
  autoRotateEnabled: boolean;
  flip: Flip;
  rotate: Rotate;
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
  paddingEnabled: boolean;
  paddingTop: number;
  paddingRight: number;
  paddingBottom: number;
  paddingLeft: number;
  backgroundEnabled: boolean;
  backgroundColor: string;
  backgroundAlphaEnabled: boolean;
  backgroundAlpha: number;
  gravityEnabled: boolean;
  gravityMode: GravityMode;
  gravity: Gravity;
  gravityFocalX: number;
  gravityFocalY: number;
  gravityOffsetX: number;
  gravityOffsetY: number;
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

type FocalPickerBounds = {
  left: number;
  top: number;
  width: number;
  height: number;
};

export const defaultDemoState: DemoState = {
  signature: "_",
  source: "images/dog.jpg",
  autoRotateEnabled: false,
  flip: "none",
  rotate: 0,
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
  paddingEnabled: false,
  paddingTop: 24,
  paddingRight: 24,
  paddingBottom: 24,
  paddingLeft: 24,
  backgroundEnabled: false,
  backgroundColor: "#ffffff",
  backgroundAlphaEnabled: false,
  backgroundAlpha: 0.5,
  gravityEnabled: false,
  gravityMode: "anchor",
  gravity: "ce",
  gravityFocalX: 0.5,
  gravityFocalY: 0.5,
  gravityOffsetX: 0,
  gravityOffsetY: 0,
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

  if (currentState.rotate !== 0) {
    segments.push(`rot:${currentState.rotate}`);
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

  if (currentState.paddingEnabled) {
    segments.push(
      [
        "pd",
        currentState.paddingTop,
        currentState.paddingRight,
        currentState.paddingBottom,
        currentState.paddingLeft
      ].join(":")
    );
  }

  if (currentState.backgroundEnabled) {
    segments.push(`bg:${currentState.backgroundColor.replace(/^#/, "")}`);

    if (currentState.backgroundAlphaEnabled) {
      segments.push(`bga:${currentState.backgroundAlpha}`);
    }
  }

  if (
    currentState.gravityEnabled &&
    (currentState.resizeEnabled || (currentState.cropEnabled && currentState.cropGravity === "inherit"))
  ) {
    segments.push(gravitySegment(currentState));
  }

  if (currentState.formatEnabled) {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.qualityEnabled) {
    segments.push(`q:${currentState.quality}`);
  }

  return segments;
}

export function gravitySegment(currentState: DemoState): string {
  if (currentState.gravityMode === "focalPoint") {
    return `g:fp:${currentState.gravityFocalX}:${currentState.gravityFocalY}`;
  }

  if (currentState.gravityMode === "offset") {
    return `g:${currentState.gravity}:${currentState.gravityOffsetX}:${currentState.gravityOffsetY}`;
  }

  return `g:${currentState.gravity}`;
}

export function focalPointFromBounds(
  clientX: number,
  clientY: number,
  bounds: FocalPickerBounds
): { x: number; y: number } {
  if (bounds.width <= 0 || bounds.height <= 0) {
    return { x: 0, y: 0 };
  }

  return {
    x: roundedUnit((clientX - bounds.left) / bounds.width),
    y: roundedUnit((clientY - bounds.top) / bounds.height)
  };
}

function roundedUnit(value: number): number {
  const clamped = Math.min(1, Math.max(0, value));

  return Math.round(clamped * 100) / 100;
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
