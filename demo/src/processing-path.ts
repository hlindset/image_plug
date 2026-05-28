import { sampleImages } from "virtual:sample-images";

export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type GravityMode = "anchor" | "focalPoint" | "offset";
export type CropGravity = "inherit" | Gravity;
export type CropDimensionUnit = "px" | "percent" | "full";
export type ResizeDimensionUnit = "px" | "auto";
export type OutputFormat = "webp" | "avif" | "jpeg" | "png";
export type Flip = "none" | "horizontal" | "vertical" | "both";
export type Rotate = 0 | 90 | 180 | 270;
export type SignatureMode = "unsigned" | "signed";
export type SourceImage = (typeof sampleImages)[number]["path"];

export type DemoState = {
  signatureMode: SignatureMode;
  signatureKey: string;
  signatureSalt: string;
  source: SourceImage;
  autoRotateEnabled: boolean;
  flip: Flip;
  rotate: Rotate;
  resizeEnabled: boolean;
  resizeMode: ResizeMode;
  resizeWidthUnit: ResizeDimensionUnit;
  width: number;
  resizeHeightUnit: ResizeDimensionUnit;
  height: number;
  resizeExtendEnabled: boolean;
  zoomEnabled: boolean;
  zoom: number;
  dprEnabled: boolean;
  dpr: number;
  minWidthEnabled: boolean;
  minWidth: number;
  minHeightEnabled: boolean;
  minHeight: number;
  aspectCanvasEnabled: boolean;
  extendAspectWidth: number;
  extendAspectHeight: number;
  paddingEnabled: boolean;
  paddingTop: number;
  paddingRight: number;
  paddingBottom: number;
  paddingLeft: number;
  backgroundEnabled: boolean;
  backgroundColor: string;
  backgroundAlpha: number;
  blurEnabled: boolean;
  blur: number;
  sharpenEnabled: boolean;
  sharpen: number;
  pixelateEnabled: boolean;
  pixelate: number;
  gravityEnabled: boolean;
  gravityMode: GravityMode;
  gravity: Gravity;
  gravityFocalX: number;
  gravityFocalY: number;
  gravityOffsetX: number;
  gravityOffsetY: number;
  enlarge: boolean;
  cropEnabled: boolean;
  cropWidthUnit: CropDimensionUnit;
  cropWidth: number;
  cropWidthPercent: number;
  cropHeightUnit: CropDimensionUnit;
  cropHeight: number;
  cropHeightPercent: number;
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
  contentType: string | null;
};

export type NumericControlLimit = {
  min: number;
  max: number;
  step: number;
};

export type ImageDimensionAxis = "width" | "height";

type FocalPickerBounds = {
  left: number;
  top: number;
  width: number;
  height: number;
};

type ResourceTimingSize = Pick<PerformanceResourceTiming, "name"> &
  Partial<Pick<PerformanceResourceTiming, "decodedBodySize" | "encodedBodySize">>;

export const controlLimits = {
  resize: {
    width: { min: 1, max: 1600, step: 1 },
    height: { min: 1, max: 1000, step: 1 },
  },
  crop: {
    percent: { min: 1, max: 99, step: 1 },
  },
  scale: {
    zoom: { min: 0.1, max: 4, step: 0.1 },
    dpr: { min: 0.1, max: 4, step: 0.1 },
    minWidth: { min: 0, max: 1600, step: 1 },
    minHeight: { min: 0, max: 1000, step: 1 },
  },
  aspectCanvas: {
    width: { min: 1, max: 32, step: 1 },
    height: { min: 1, max: 32, step: 1 },
  },
  padding: { min: 0, max: 240, step: 1 },
  alpha: { min: 0, max: 1, step: 0.1 },
  effects: {
    blur: { min: 0.1, max: 10, step: 0.1 },
    sharpen: { min: 0.1, max: 10, step: 0.1 },
    pixelate: { min: 2, max: 80, step: 1 },
  },
  focalPoint: { min: 0, max: 1, step: 0.01 },
  gravityOffset: { min: -200, max: 200, step: 0.01 },
  quality: { min: 0, max: 100, step: 1 },
} satisfies {
  resize: Record<ImageDimensionAxis, NumericControlLimit>;
  crop: { percent: NumericControlLimit };
  scale: Record<"zoom" | "dpr" | "minWidth" | "minHeight", NumericControlLimit>;
  aspectCanvas: Record<ImageDimensionAxis, NumericControlLimit>;
  padding: NumericControlLimit;
  alpha: NumericControlLimit;
  effects: Record<"blur" | "sharpen" | "pixelate", NumericControlLimit>;
  focalPoint: NumericControlLimit;
  gravityOffset: NumericControlLimit;
  quality: NumericControlLimit;
};

export { sampleImages };

const sourceImageDimensions = Object.fromEntries(
  sampleImages.map((image) => [image.path, { width: image.width, height: image.height }]),
) as Record<SourceImage, Record<ImageDimensionAxis, number>>;

export function cropPixelLimit(source: SourceImage, axis: ImageDimensionAxis): NumericControlLimit {
  return { min: 1, max: sourceImageDimensions[source]?.[axis] ?? 1, step: 1 };
}

function sourceDimension(source: SourceImage, axis: ImageDimensionAxis): number {
  return cropPixelLimit(source, axis).max;
}

export function resetCropPixelsToSource(currentState: DemoState): DemoState {
  return {
    ...currentState,
    cropWidth: sourceDimension(currentState.source, "width"),
    cropHeight: sourceDimension(currentState.source, "height"),
  };
}

export function debounce<Arguments extends unknown[]>(
  callback: (...args: Arguments) => void,
  delayMs: number,
): (...args: Arguments) => void {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;

  return (...args: Arguments) => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }

    timeoutId = setTimeout(() => {
      callback(...args);
    }, delayMs);
  };
}

export const defaultDemoState: DemoState = {
  signatureMode: "unsigned",
  signatureKey: "736563726574",
  signatureSalt: "68656c6c6f",
  source: "images/dog.jpg",
  autoRotateEnabled: false,
  flip: "none",
  rotate: 0,
  resizeEnabled: false,
  resizeMode: "fill",
  resizeWidthUnit: "px",
  width: 640,
  resizeHeightUnit: "px",
  height: 360,
  resizeExtendEnabled: false,
  zoomEnabled: false,
  zoom: 1.5,
  dprEnabled: false,
  dpr: 2,
  minWidthEnabled: false,
  minWidth: 320,
  minHeightEnabled: false,
  minHeight: 180,
  aspectCanvasEnabled: false,
  extendAspectWidth: 16,
  extendAspectHeight: 9,
  paddingEnabled: false,
  paddingTop: 24,
  paddingRight: 24,
  paddingBottom: 24,
  paddingLeft: 24,
  backgroundEnabled: false,
  backgroundColor: "#ffffff",
  backgroundAlpha: 1,
  blurEnabled: false,
  blur: 2,
  sharpenEnabled: false,
  sharpen: 1,
  pixelateEnabled: false,
  pixelate: 8,
  gravityEnabled: false,
  gravityMode: "anchor",
  gravity: "ce",
  gravityFocalX: 0.5,
  gravityFocalY: 0.5,
  gravityOffsetX: 0,
  gravityOffsetY: 0,
  enlarge: false,
  cropEnabled: false,
  cropWidthUnit: "px",
  cropWidth: sourceDimension("images/dog.jpg", "width"),
  cropWidthPercent: 50,
  cropHeightUnit: "px",
  cropHeight: sourceDimension("images/dog.jpg", "height"),
  cropHeightPercent: 50,
  cropGravity: "inherit",
  formatEnabled: false,
  format: "jpeg",
  qualityEnabled: false,
  quality: 85,
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

  const cropSegment = cropOptionSegment(currentState);

  if (cropSegment !== null) {
    segments.push(cropSegment);
  }

  const resizeSegment = resizeOptionSegment(currentState);

  if (resizeSegment !== null) {
    segments.push(resizeSegment);
  }

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

  if (currentState.aspectCanvasEnabled) {
    segments.push(`exar:${currentState.extendAspectWidth}:${currentState.extendAspectHeight}`);
  }

  if (currentState.paddingEnabled) {
    segments.push(
      [
        "pd",
        currentState.paddingTop,
        currentState.paddingRight,
        currentState.paddingBottom,
        currentState.paddingLeft,
      ].join(":"),
    );
  }

  if (currentState.backgroundEnabled) {
    segments.push(`bg:${currentState.backgroundColor.replace(/^#/, "")}`);

    if (currentState.backgroundAlpha < 1) {
      segments.push(`bga:${currentState.backgroundAlpha}`);
    }
  }

  if (currentState.blurEnabled) {
    segments.push(`bl:${currentState.blur}`);
  }

  if (currentState.sharpenEnabled) {
    segments.push(`sh:${currentState.sharpen}`);
  }

  if (currentState.pixelateEnabled) {
    segments.push(`pix:${currentState.pixelate}`);
  }

  if (currentState.gravityEnabled) {
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

export function cropOptionSegment(currentState: DemoState): string | null {
  if (!currentState.cropEnabled) {
    return null;
  }

  const cropSegment = [
    "c",
    cropDimensionSegment(
      currentState.cropWidthUnit,
      currentState.cropWidth,
      currentState.cropWidthPercent,
    ),
    cropDimensionSegment(
      currentState.cropHeightUnit,
      currentState.cropHeight,
      currentState.cropHeightPercent,
    ),
  ];

  if (currentState.cropGravity !== "inherit") {
    cropSegment.push(currentState.cropGravity);
  }

  return cropSegment.join(":");
}

export function resizeOptionSegment(currentState: DemoState): string | null {
  if (!currentState.resizeEnabled) {
    return null;
  }

  const resizeSegment = [
    "rs",
    currentState.resizeMode,
    resizeDimensionSegment(currentState.resizeWidthUnit, currentState.width),
    resizeDimensionSegment(currentState.resizeHeightUnit, currentState.height),
    currentState.enlarge ? 1 : 0,
  ];

  if (currentState.resizeExtendEnabled) {
    resizeSegment.push(1);
  }

  return resizeSegment.join(":");
}

export function cropDimensionSegment(
  unit: CropDimensionUnit,
  pixels: number,
  percent: number,
): string {
  if (unit === "full") {
    return "0";
  }

  if (unit === "percent") {
    return String(percent / 100);
  }

  return String(Math.max(1, pixels));
}

export function resizeDimensionSegment(unit: ResizeDimensionUnit, pixels: number): string {
  if (unit === "auto") {
    return "0";
  }

  return String(pixels);
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
  bounds: FocalPickerBounds,
): { x: number; y: number } {
  if (bounds.width <= 0 || bounds.height <= 0) {
    return { x: 0, y: 0 };
  }

  return {
    x: roundedUnit((clientX - bounds.left) / bounds.width),
    y: roundedUnit((clientY - bounds.top) / bounds.height),
  };
}

function roundedUnit(value: number): number {
  const clamped = Math.min(1, Math.max(0, value));

  return Math.round(clamped * 100) / 100;
}

export function resolvedOutputLabel(
  currentState: DemoState,
  metadata: ProcessedImageMetadata | null = null,
): string {
  if (!currentState.formatEnabled) {
    const negotiatedFormat = outputFormatFromContentType(metadata?.contentType ?? null);

    if (negotiatedFormat !== null) {
      return `auto -> ${negotiatedFormat}`;
    }

    return "auto";
  }

  return currentState.format;
}

function outputFormatFromContentType(contentType: string | null): string | null {
  if (contentType === null) {
    return null;
  }

  const [mimeType] = contentType.toLowerCase().split(";");

  if (mimeType === "image/jpeg") {
    return "jpeg";
  }

  return mimeType?.startsWith("image/") === true ? mimeType.slice("image/".length) : null;
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

export function imageRequestBytesFromPerformance(
  imageUrl: string,
  entries: readonly ResourceTimingSize[],
): number | null {
  const matchingEntries = entries.filter((entry) => entry.name === imageUrl);

  for (const entry of matchingEntries.toReversed()) {
    const bytes = entry.encodedBodySize || entry.decodedBodySize || 0;

    if (bytes > 0) {
      return bytes;
    }
  }

  return null;
}

export function sourceIdentifierForRequest(source: SourceImage): string {
  return `local:///${source}`;
}

export function signedPathForState(currentState: DemoState): string {
  const options = optionSegments(currentState).join("/");
  const optionsPath = options === "" ? "" : `/${options}`;

  return `${optionsPath}/plain/${sourceIdentifierForRequest(currentState.source)}`;
}

export function processingPathFromSignedPath(signature: string, signedPath: string): string {
  return `/${signature}${signedPath}`;
}

export function buildProcessingPath(currentState: DemoState, signature?: string): string {
  const signedPath = signedPathForState(currentState);

  if (signature !== undefined) {
    return processingPathFromSignedPath(signature, signedPath);
  }

  return processingPathFromSignedPath(signatureSegment(), signedPath);
}

export async function signProcessingPath(
  signedPath: string,
  keyHex: string,
  saltHex: string,
  signatureSize = 32,
): Promise<string> {
  if (!Number.isInteger(signatureSize) || signatureSize < 1 || signatureSize > 32) {
    throw new RangeError("signatureSize must be an integer between 1 and 32");
  }

  const key = hexToBytes(keyHex, "key");
  const salt = hexToBytes(saltHex, "salt");
  const pathBytes = new TextEncoder().encode(signedPath);
  const data = new Uint8Array(salt.length + pathBytes.length);

  data.set(salt);
  data.set(pathBytes, salt.length);

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    toArrayBuffer(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, toArrayBuffer(data)));
  const signature = digest.slice(0, signatureSize);

  return base64UrlEncode(signature);
}

function signatureSegment(): string {
  return "_";
}

function hexToBytes(hex: string, label: string): Uint8Array {
  if (hex === "" || hex.length % 2 !== 0 || !/^[\da-f]+$/i.test(hex)) {
    throw new Error(`Signing ${label} must be a non-empty hex string`);
  }

  const bytes = new Uint8Array(hex.length / 2);

  for (let index = 0; index < hex.length; index += 2) {
    bytes[index / 2] = Number.parseInt(hex.slice(index, index + 2), 16);
  }

  return bytes;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);

  new Uint8Array(buffer).set(bytes);

  return buffer;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
