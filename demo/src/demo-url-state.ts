import {
  defaultDemoState,
  resetCropPixelsToSource,
  sampleImages,
  signedPathForState,
  type CropDimensionUnit,
  type DemoState,
  type Flip,
  type Gravity,
  type OutputFormat,
  type ResizeDimensionUnit,
  type ResizeMode,
  type Rotate,
  type SourceImage,
} from "./processing-path";

export type ExpandedToolboxes = {
  orientationOpen: boolean;
  requestOpen: boolean;
  scaleOptionsOpen: boolean;
};

type ParsedDimension<Unit> = {
  unit: Unit;
  value: number;
};

const demoPathPrefix = "/demo";
const sourceImages = new Set<string>(sampleImages.map((image) => image.path));
const resizeModes = new Set<string>(["fit", "fill", "fill-down", "force", "auto"]);
const gravityValues = new Set<string>([
  "ce",
  "no",
  "so",
  "ea",
  "we",
  "noea",
  "nowe",
  "soea",
  "sowe",
]);
const outputFormats = new Set<string>(["webp", "avif", "jpeg", "png"]);
const rotations = new Set<number>([90, 180, 270]);

export function demoPathForState(currentState: DemoState): string {
  return `${demoPathPrefix}${signedPathForState(currentState)}`;
}

export function parseDemoPath(pathname: string): DemoState {
  const parsed = parseDemoPathParts(pathname);

  if (parsed === null) {
    return { ...defaultDemoState };
  }

  let state = resetCropPixelsToSource({
    ...defaultDemoState,
    source: parsed.source,
  });

  for (const segment of parsed.optionSegments) {
    const nextState = applyOptionSegment(state, segment);

    if (nextState === null) {
      return { ...defaultDemoState };
    }

    state = nextState;
  }

  return state;
}

export function expandedToolboxesForState(currentState: DemoState): ExpandedToolboxes {
  return {
    orientationOpen:
      currentState.autoRotateEnabled || currentState.flip !== "none" || currentState.rotate !== 0,
    requestOpen: true,
    scaleOptionsOpen:
      currentState.zoomEnabled ||
      currentState.dprEnabled ||
      currentState.minWidthEnabled ||
      currentState.minHeightEnabled,
  };
}

function parseDemoPathParts(
  pathname: string,
): { optionSegments: string[]; source: SourceImage } | null {
  const path = pathname.endsWith("/") && pathname !== "/" ? pathname.slice(0, -1) : pathname;

  if (path !== demoPathPrefix && !path.startsWith(`${demoPathPrefix}/`)) {
    return null;
  }

  const segments = path.slice(demoPathPrefix.length).split("/").filter(Boolean);
  const plainIndex = segments.indexOf("plain");

  if (plainIndex === -1) {
    return null;
  }

  const source = segments.slice(plainIndex + 1).join("/");

  if (!sourceImages.has(source)) {
    return null;
  }

  return {
    optionSegments: segments.slice(0, plainIndex),
    source: source as SourceImage,
  };
}

function applyOptionSegment(currentState: DemoState, segment: string): DemoState | null {
  const [name = "", ...args] = segment.split(":");

  switch (name) {
    case "ar":
      return parseAutoRotate(currentState, args);

    case "fl":
      return parseFlip(currentState, args);

    case "rot":
      return parseRotate(currentState, args);

    case "c":
    case "crop":
      return parseCrop(currentState, args);

    case "rs":
    case "resize":
      return parseResize(currentState, args);

    case "z":
      return parseNumericOption(currentState, args, (value) => ({
        zoomEnabled: true,
        zoom: value,
      }));

    case "dpr":
      return parseNumericOption(currentState, args, (value) => ({ dprEnabled: true, dpr: value }));

    case "mw":
      return parseNumericOption(currentState, args, (value) => ({
        minWidthEnabled: true,
        minWidth: value,
      }));

    case "mh":
      return parseNumericOption(currentState, args, (value) => ({
        minHeightEnabled: true,
        minHeight: value,
      }));

    case "exar":
      return parseAspectCanvas(currentState, args);

    case "pd":
      return parsePadding(currentState, args);

    case "bg":
      return parseBackground(currentState, args);

    case "bga":
      return parseBackgroundAlpha(currentState, args);

    case "g":
      return parseGravity(currentState, args);

    case "f":
      return parseFormat(currentState, args);

    case "q":
      return parseQuality(currentState, args);

    default:
      return null;
  }
}

function parseAutoRotate(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1 || args[0] !== "1") {
    return null;
  }

  return { ...currentState, autoRotateEnabled: true };
}

function parseFlip(currentState: DemoState, args: string[]): DemoState | null {
  const flip = flipFromArgs(args);

  if (flip === null) {
    return null;
  }

  return { ...currentState, flip };
}

function flipFromArgs(args: string[]): Flip | null {
  if (args.length === 0) {
    return "both";
  }

  if (args.length === 1 && args[0] === "1") {
    return "horizontal";
  }

  if (args.length === 2 && args[0] === "0" && args[1] === "1") {
    return "vertical";
  }

  return null;
}

function parseRotate(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1) {
    return null;
  }

  const rotate = parseNumber(args[0]);

  if (rotate === null || !rotations.has(rotate)) {
    return null;
  }

  return { ...currentState, rotate: rotate as Rotate };
}

function parseCrop(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length < 2 || args.length > 3) {
    return null;
  }

  const [widthArg, heightArg, gravityArg] = args as [string, string, string?];
  const width = parseCropDimension(widthArg);
  const height = parseCropDimension(heightArg);
  const gravity = gravityArg ?? "inherit";

  if (width === null || height === null || (gravity !== "inherit" && !isGravity(gravity))) {
    return null;
  }

  return {
    ...currentState,
    cropEnabled: true,
    cropWidthUnit: width.unit,
    cropWidth: width.unit === "px" ? width.value : currentState.cropWidth,
    cropWidthPercent: width.unit === "percent" ? width.value : currentState.cropWidthPercent,
    cropHeightUnit: height.unit,
    cropHeight: height.unit === "px" ? height.value : currentState.cropHeight,
    cropHeightPercent: height.unit === "percent" ? height.value : currentState.cropHeightPercent,
    cropGravity: gravity,
  };
}

function parseCropDimension(value: string): ParsedDimension<CropDimensionUnit> | null {
  const number = parseNumber(value);

  if (number === null || number < 0) {
    return null;
  }

  if (number === 0) {
    return { unit: "full", value: 0 };
  }

  if (number < 1) {
    return { unit: "percent", value: number * 100 };
  }

  return { unit: "px", value: number };
}

function parseResize(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length < 4 || args.length > 5) {
    return null;
  }

  const [mode, widthArg, heightArg, enlargeArg, extendArg] = args as [
    string,
    string,
    string,
    string,
    string?,
  ];
  const width = parseResizeDimension(widthArg);
  const height = parseResizeDimension(heightArg);

  if (
    !resizeModes.has(mode) ||
    width === null ||
    height === null ||
    !isBooleanArg(enlargeArg) ||
    (extendArg !== undefined && !isBooleanArg(extendArg))
  ) {
    return null;
  }

  return {
    ...currentState,
    resizeEnabled: true,
    resizeMode: mode as ResizeMode,
    resizeWidthUnit: width.unit,
    width: width.unit === "px" ? width.value : currentState.width,
    resizeHeightUnit: height.unit,
    height: height.unit === "px" ? height.value : currentState.height,
    enlarge: enlargeArg === "1",
    resizeExtendEnabled: extendArg === "1",
  };
}

function parseResizeDimension(value: string): ParsedDimension<ResizeDimensionUnit> | null {
  const number = parseNumber(value);

  if (number === null || number < 0) {
    return null;
  }

  if (number === 0) {
    return { unit: "auto", value: 0 };
  }

  return { unit: "px", value: number };
}

function parseNumericOption(
  currentState: DemoState,
  args: string[],
  buildPatch: (value: number) => Partial<DemoState>,
): DemoState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseNumber(args[0]);

  if (value === null) {
    return null;
  }

  return { ...currentState, ...buildPatch(value) };
}

function parseAspectCanvas(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 2) {
    return null;
  }

  const width = parseNumber(args[0]);
  const height = parseNumber(args[1]);

  if (width === null || height === null) {
    return null;
  }

  return {
    ...currentState,
    aspectCanvasEnabled: true,
    extendAspectWidth: width,
    extendAspectHeight: height,
  };
}

function parsePadding(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 4) {
    return null;
  }

  const [topArg, rightArg, bottomArg, leftArg] = args as [string, string, string, string];
  const top = parseNumber(topArg);
  const right = parseNumber(rightArg);
  const bottom = parseNumber(bottomArg);
  const left = parseNumber(leftArg);

  if (top === null || right === null || bottom === null || left === null) {
    return null;
  }

  return {
    ...currentState,
    paddingEnabled: true,
    paddingTop: top,
    paddingRight: right,
    paddingBottom: bottom,
    paddingLeft: left,
  };
}

function parseBackground(currentState: DemoState, args: string[]): DemoState | null {
  const [color] = args as [string?];

  if (args.length !== 1 || color === undefined || !/^[\da-f]{6}$/i.test(color)) {
    return null;
  }

  return {
    ...currentState,
    backgroundEnabled: true,
    backgroundColor: `#${color.toLowerCase()}`,
  };
}

function parseBackgroundAlpha(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1) {
    return null;
  }

  const alpha = parseNumber(args[0]);

  if (alpha === null || alpha < 0 || alpha > 1) {
    return null;
  }

  return {
    ...currentState,
    backgroundEnabled: true,
    backgroundAlpha: alpha,
  };
}

function parseGravity(currentState: DemoState, args: string[]): DemoState | null {
  const [modeOrGravity, xArg, yArg] = args as [string?, string?, string?];

  if (args.length === 1 && modeOrGravity !== undefined && isGravity(modeOrGravity)) {
    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "anchor",
      gravity: modeOrGravity,
    };
  }

  if (args.length === 3 && modeOrGravity === "fp") {
    const x = parseNumber(xArg);
    const y = parseNumber(yArg);

    if (x === null || y === null || x < 0 || x > 1 || y < 0 || y > 1) {
      return null;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "focalPoint",
      gravityFocalX: x,
      gravityFocalY: y,
    };
  }

  if (args.length === 3 && modeOrGravity !== undefined && isGravity(modeOrGravity)) {
    const x = parseNumber(xArg);
    const y = parseNumber(yArg);

    if (x === null || y === null) {
      return null;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "offset",
      gravity: modeOrGravity,
      gravityOffsetX: x,
      gravityOffsetY: y,
    };
  }

  return null;
}

function parseFormat(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1 || !outputFormats.has(args[0] ?? "")) {
    return null;
  }

  return {
    ...currentState,
    formatEnabled: true,
    format: args[0] as OutputFormat,
  };
}

function parseQuality(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1) {
    return null;
  }

  const quality = parseNumber(args[0]);

  if (quality === null) {
    return null;
  }

  return {
    ...currentState,
    qualityEnabled: true,
    quality,
  };
}

function isGravity(value: string): value is Gravity {
  return gravityValues.has(value);
}

function isBooleanArg(value: string): boolean {
  return value === "0" || value === "1";
}

function parseNumber(value: string | undefined): number | null {
  if (value === undefined || value.trim() === "") {
    return null;
  }

  const number = Number(value);

  return Number.isFinite(number) ? number : null;
}
