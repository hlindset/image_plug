import { afterEach, describe, expect, it, vi } from "vitest";

import {
  buildProcessingPath,
  cocoClasses,
  controlLimits,
  cropDimensionSegment,
  cropOptionSegment,
  cropPixelLimit,
  type DemoState,
  defaultDemoState,
  debounce,
  focalPointFromBounds,
  imageRequestBytesFromPerformance,
  objGravitySegment,
  objGravitySegmentFromState,
  resetCropPixelsToSource,
  processedSizeLabel,
  optionSegments,
  processingPathFromSignedPath,
  resizeOptionSegment,
  resolvedOutputLabel,
  signProcessingPath,
  signedPathForState,
  trimOptionSegment,
} from "./processing-path";
import {
  demoPathForState,
  expandedToolboxesForState,
  parseDemoPath,
  resetDemoSettings,
} from "./demo-url-state";

const activeDemoState = {
  ...defaultDemoState,
  resizeEnabled: true,
  gravityEnabled: true,
  qualityEnabled: true,
};

afterEach(() => {
  vi.useRealTimers();
});

describe("debounce", () => {
  it("runs only the latest scheduled callback after the delay", () => {
    vi.useFakeTimers();

    const calls: string[] = [];
    const schedule = debounce((value: string) => calls.push(value), 150);

    schedule("first");
    vi.advanceTimersByTime(100);
    schedule("second");
    vi.advanceTimersByTime(149);

    expect(calls).toEqual([]);

    vi.advanceTimersByTime(1);

    expect(calls).toEqual(["second"]);
  });
});

describe("processing path generation", () => {
  it("defines shared control limits for slider-backed inputs", () => {
    expect(controlLimits.quality).toEqual({ min: 0, max: 100, step: 1 });
    expect(controlLimits.crop.percent).toEqual({ min: 1, max: 99, step: 1 });
    expect(controlLimits.resize.width).toEqual({ min: 1, max: 1600, step: 1 });
  });

  it("uses the source image dimensions as crop pixel limits", () => {
    expect(cropPixelLimit("images/dog.jpg", "width")).toEqual({ min: 1, max: 5011, step: 1 });
    expect(cropPixelLimit("images/dog.jpg", "height")).toEqual({ min: 1, max: 7516, step: 1 });
    expect(cropPixelLimit("images/beach.jpg", "width")).toEqual({ min: 1, max: 4000, step: 1 });
    expect(cropPixelLimit("images/beach.jpg", "height")).toEqual({ min: 1, max: 2667, step: 1 });
  });

  it("defaults crop pixel dimensions to the default source dimensions", () => {
    expect(defaultDemoState.cropWidth).toBe(cropPixelLimit(defaultDemoState.source, "width").max);
    expect(defaultDemoState.cropHeight).toBe(cropPixelLimit(defaultDemoState.source, "height").max);
  });

  it("can reset crop pixel dimensions to the selected source dimensions", () => {
    expect(
      resetCropPixelsToSource({
        ...defaultDemoState,
        source: "images/beach.jpg",
        cropWidth: 1,
        cropHeight: 1,
      }),
    ).toMatchObject({
      cropWidth: 4000,
      cropHeight: 2667,
    });
  });

  it("builds the default processing path", () => {
    expect(optionSegments(defaultDemoState)).toEqual([]);
    expect(buildProcessingPath(defaultDemoState)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("builds a signed request path from a generated signature", () => {
    const state = {
      ...defaultDemoState,
      signatureMode: "signed" as const,
      resizeEnabled: true,
    };

    expect(signedPathForState(state)).toBe("/rs:fill:640:360:0/plain/local:///images/dog.jpg");
    expect(processingPathFromSignedPath("local-signature", signedPathForState(state))).toBe(
      "/img/local-signature/rs:fill:640:360:0/plain/local:///images/dog.jpg",
    );
  });

  it("generates imgproxy-compatible HMAC signatures", async () => {
    const signature = await signProcessingPath(
      "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png",
      "736563726574",
      "68656c6c6f",
    );

    expect(signature).toBe("oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8");
  });

  it("rejects invalid signature sizes before signing", async () => {
    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 0),
    ).rejects.toThrow(RangeError);

    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 33),
    ).rejects.toThrow("signatureSize must be an integer between 1 and 32");

    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 1.5),
    ).rejects.toThrow("signatureSize must be an integer between 1 and 32");
  });

  it("keeps jpeg selected as the default explicit format", () => {
    expect(defaultDemoState.format).toBe("jpeg");
  });

  it("reads processed byte size from the latest matching resource timing entry", () => {
    const entries = [
      { name: "http://localhost:4000/_/plain/local:///images/dog.jpg", encodedBodySize: 120 },
      { name: "http://localhost:4000/_/plain/local:///images/cat.jpg", encodedBodySize: 90 },
      { name: "http://localhost:4000/_/plain/local:///images/dog.jpg", encodedBodySize: 456 },
    ];

    expect(
      imageRequestBytesFromPerformance(
        "http://localhost:4000/_/plain/local:///images/dog.jpg",
        entries,
      ),
    ).toBe(456);
  });

  it("falls back to decoded resource timing size and ignores unavailable sizes", () => {
    const entries = [
      {
        name: "http://localhost:4000/_/plain/local:///images/dog.jpg",
        encodedBodySize: 0,
        decodedBodySize: 321,
      },
      {
        name: "http://localhost:4000/_/plain/local:///images/dog.jpg",
        encodedBodySize: 0,
        decodedBodySize: 0,
      },
    ];

    expect(
      imageRequestBytesFromPerformance(
        "http://localhost:4000/_/plain/local:///images/dog.jpg",
        entries,
      ),
    ).toBe(321);
  });

  it("includes auto rotate as an explicit orientation option", () => {
    const state = {
      ...defaultDemoState,
      autoRotateEnabled: true,
    };

    expect(optionSegments(state)).toEqual(["ar:1"]);
    expect(buildProcessingPath(state)).toBe("/img/_/ar:1/plain/local:///images/dog.jpg");
  });

  it("includes flip options for each supported flip axis", () => {
    expect(optionSegments({ ...defaultDemoState, flip: "horizontal" })).toEqual(["fl:1"]);
    expect(optionSegments({ ...defaultDemoState, flip: "vertical" })).toEqual(["fl:0:1"]);
    expect(optionSegments({ ...defaultDemoState, flip: "both" })).toEqual(["fl"]);
  });

  it("includes rotate when a right-angle rotation is selected", () => {
    expect(optionSegments({ ...defaultDemoState, rotate: 90 })).toEqual(["rot:90"]);
    expect(optionSegments({ ...defaultDemoState, rotate: 180 })).toEqual(["rot:180"]);
    expect(optionSegments({ ...defaultDemoState, rotate: 270 })).toEqual(["rot:270"]);
  });

  it("emits nothing for trim when disabled", () => {
    expect(trimOptionSegment(defaultDemoState)).toBeNull();
    expect(optionSegments(defaultDemoState)).toEqual([]);
  });

  it("emits trim with threshold only when background is auto and flags are off", () => {
    const state = {
      ...defaultDemoState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto" as const,
      trimEqualHor: false,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:10");
    expect(optionSegments(state)).toEqual(["trim:10"]);
    expect(buildProcessingPath(state)).toBe("/img/_/trim:10/plain/local:///images/dog.jpg");
  });

  it("emits trim with color when background mode is color", () => {
    const state = {
      ...defaultDemoState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "color" as const,
      trimColor: "#ff00ff",
      trimEqualHor: false,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:10:ff00ff");
  });

  it("emits trim with empty color slot when auto background but flags are set", () => {
    const state = {
      ...defaultDemoState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto" as const,
      trimEqualHor: true,
      trimEqualVer: true,
    };

    expect(trimOptionSegment(state)).toBe("trim:10::1:1");
  });

  it("emits trim with color and flags", () => {
    const state = {
      ...defaultDemoState,
      trimEnabled: true,
      trimThreshold: 20,
      trimBackgroundMode: "color" as const,
      trimColor: "#ff00ff",
      trimEqualHor: true,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:20:ff00ff:1:0");
  });

  it("emits trim before crop in the option segment order", () => {
    const state = {
      ...defaultDemoState,
      trimEnabled: true,
      trimThreshold: 10,
      cropEnabled: true,
      cropWidth: 320,
      cropHeight: 240,
    };

    const segs = optionSegments(state);
    const trimIdx = segs.findIndex((s) => s.startsWith("trim:"));
    const cropIdx = segs.findIndex((s) => s.startsWith("c:"));

    expect(trimIdx).toBeGreaterThanOrEqual(0);
    expect(cropIdx).toBeGreaterThanOrEqual(0);
    expect(trimIdx).toBeLessThan(cropIdx);
  });

  it("includes resize extend as the resize segment extend argument", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      resizeExtendEnabled: true,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0:1"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0:1/plain/local:///images/dog.jpg",
    );
  });

  it("builds the resize tool summary from the emitted resize segment", () => {
    expect(resizeOptionSegment(defaultDemoState)).toBeNull();

    expect(resizeOptionSegment({ ...defaultDemoState, resizeEnabled: true })).toBe(
      "rs:fill:640:360:0",
    );

    expect(
      resizeOptionSegment({
        ...defaultDemoState,
        resizeEnabled: true,
        resizeWidthUnit: "auto" as const,
        resizeHeightUnit: "px" as const,
        height: 360,
      }),
    ).toBe("rs:fill:0:360:0");
  });

  it("emits resize auto dimensions as zero per axis", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      resizeWidthUnit: "auto" as const,
      resizeHeightUnit: "px" as const,
      height: 360,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:0:360:0"]);
  });

  it("allows both resize dimensions to be auto", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      resizeMode: "force" as const,
      resizeWidthUnit: "auto" as const,
      resizeHeightUnit: "auto" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:force:0:0:0"]);
  });

  it("does not emit resize extend when resize is disabled", () => {
    const state = {
      ...defaultDemoState,
      resizeExtendEnabled: true,
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("includes extend aspect ratio when aspect canvas is enabled", () => {
    const state = {
      ...defaultDemoState,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "ce" as const,
    };

    expect(optionSegments(state)).toEqual(["exar:1"]);
    expect(buildProcessingPath(state)).toBe("/img/_/exar:1/plain/local:///images/dog.jpg");
  });

  it("round-trips exar with gravity", () => {
    const state = {
      ...defaultDemoState,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "no" as const,
    };
    expect(optionSegments(state)).toEqual(["exar:1:no"]);
  });

  it("includes explicit four-sided padding after aspect canvas options", () => {
    const state = {
      ...defaultDemoState,
      aspectCanvasEnabled: true,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 16,
      paddingBottom: 24,
      paddingLeft: 32,
    };

    expect(optionSegments(state)).toEqual(["exar:1", "pd:8:16:24:32"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/exar:1/pd:8:16:24:32/plain/local:///images/dog.jpg",
    );
  });

  it("includes background color and opacity after padding", () => {
    const state = {
      ...defaultDemoState,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 8,
      paddingBottom: 8,
      paddingLeft: 8,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.5,
    };

    expect(optionSegments(state)).toEqual(["pd:8:8:8:8", "bg:ffcc00", "bga:0.5"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/pd:8:8:8:8/bg:ffcc00/bga:0.5/plain/local:///images/dog.jpg",
    );
  });

  it("includes basic effects after background options", () => {
    const state = {
      ...defaultDemoState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      blurEnabled: true,
      blur: 2.5,
      sharpenEnabled: true,
      sharpen: 0.7,
      pixelateEnabled: true,
      pixelate: 8,
      monochromeEnabled: true,
      monochromeIntensity: 0.5,
      monochromeColor: "#ffcc00",
      duotoneEnabled: true,
      duotoneIntensity: 0.25,
      duotoneShadow: "#112233",
      duotoneHighlight: "#ffeecc",
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: -15,
      saturationEnabled: true,
      saturation: 35,
    };

    expect(optionSegments(state)).toEqual([
      "bg:ffcc00",
      "bl:2.5",
      "sh:0.7",
      "pix:8",
      "mc:0.5:ffcc00",
      "dt:0.25:112233:ffeecc",
      "br:20",
      "co:-15",
      "sa:35",
    ]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/bg:ffcc00/bl:2.5/sh:0.7/pix:8/mc:0.5:ffcc00/dt:0.25:112233:ffeecc/br:20/co:-15/sa:35/plain/local:///images/dog.jpg",
    );
  });

  it("omits background alpha when opacity is full", () => {
    const state = {
      ...defaultDemoState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 1,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00"]);
    expect(buildProcessingPath(state)).toBe("/img/_/bg:ffcc00/plain/local:///images/dog.jpg");
  });

  it("preserves custom background opacity decimals", () => {
    const state = {
      ...defaultDemoState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.42,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00", "bga:0.42"]);
  });

  it("allows fully transparent background opacity", () => {
    const state = {
      ...defaultDemoState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00", "bga:0"]);
  });

  it("includes crop options before resize options when crop is enabled", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropWidth: 320,
      cropHeight: 240,
    };

    expect(optionSegments(state)).toEqual(["c:320:240", "rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("does not write inherited crop gravity into the crop segment", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "inherit" as const,
      gravity: "nowe" as const,
    };

    expect(optionSegments(state)).toEqual(["c:5011:7516", "rs:fill:640:360:0", "g:nowe", "q:85"]);
  });

  it("uses shared gravity as the top-level gravity option", () => {
    const state = {
      ...activeDemoState,
      gravity: "sowe" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:sowe", "q:85"]);
  });

  it("includes focal point global gravity", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.25,
      gravityFocalY: 0.75,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:fp:0.25:0.75"]);
  });

  it("includes focal point global gravity without requiring resize or crop", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: true,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.25,
      gravityFocalY: 0.75,
    };

    expect(optionSegments(state)).toEqual(["g:fp:0.25:0.75"]);
    expect(demoPathForState(state)).toBe("/g:fp:0.25:0.75/plain/local:///images/dog.jpg");
  });

  it("includes offset global gravity", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "offset" as const,
      gravity: "soea" as const,
      gravityOffsetX: 12,
      gravityOffsetY: -0.25,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:soea:12:-0.25"]);
  });

  it("includes smart global gravity without offsets", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "smart" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:sm"]);
  });

  it("round-trips smart global gravity through the demo path", () => {
    const parsed = parseDemoPath("/g:sm/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "smart",
    });

    expect(demoPathForState(parsed)).toBe("/g:sm/plain/local:///images/dog.jpg");
  });

  it("round-trips smart crop gravity through the demo path", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "sm" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:sm");

    const parsed = parseDemoPath(demoPathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "sm",
    });
  });

  it("includes object (face) global gravity without offsets", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "objFace" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:obj:face"]);
  });

  it("round-trips object (face) global gravity through the demo path", () => {
    const parsed = parseDemoPath("/g:obj:face/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "objFace",
    });

    expect(demoPathForState(parsed)).toBe("/g:obj:face/plain/local:///images/dog.jpg");
  });

  it("round-trips object (face) crop gravity through the demo path", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "obj:face" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj:face");

    const parsed = parseDemoPath(demoPathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj:face",
    });
  });

  // ---- Object gravity: Simple sub-mode ----

  it("emits bare g:obj for object gravity with no classes selected (simple)", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "simple" as const,
      objSelectedClasses: [],
    };

    expect(optionSegments(state)).toEqual(["g:obj"]);
  });

  it("emits g:obj:car:dog for simple mode with two classes (sorted)", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "simple" as const,
      objSelectedClasses: ["dog", "car"],
    };

    // sorted: car before dog
    expect(optionSegments(state)).toEqual(["g:obj:car:dog"]);
  });

  it("round-trips bare g:obj through the demo path", () => {
    const parsed = parseDemoPath("/g:obj/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: [],
    });

    expect(demoPathForState(parsed)).toBe("/g:obj/plain/local:///images/dog.jpg");
  });

  it("normalizes g:obj:all to bare g:obj (empty selection = all objects)", () => {
    const parsed = parseDemoPath("/g:obj:all/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: [],
    });

    expect(demoPathForState(parsed)).toBe("/g:obj/plain/local:///images/dog.jpg");
  });

  it("round-trips g:obj with explicit classes through the demo path", () => {
    const parsed = parseDemoPath("/g:obj:car:dog/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: expect.arrayContaining(["car", "dog"]),
    });

    expect(demoPathForState(parsed)).toBe("/g:obj:car:dog/plain/local:///images/dog.jpg");
  });

  it("drops class tokens not offered in the demo UI, keeping only demo-offered classes", () => {
    // 'car' is a demo class; 'spaceship' is not
    const parsed = parseDemoPath("/g:obj:car:spaceship/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSelectedClasses: ["car"],
    });

    expect(demoPathForState(parsed)).toBe("/g:obj:car/plain/local:///images/dog.jpg");
  });

  it("leaves gravity unchanged for an all-unknown g:obj segment", () => {
    const parsed = parseDemoPath("/g:obj:spaceship/plain/local:///images/dog.jpg");

    // every token unknown -> the picker can't represent it, gravity is unchanged
    expect(parsed.gravityMode).not.toBe("object");
  });

  it("g:obj:car:all — 'all' mixed with classes falls through to known-class filter", () => {
    // 'all' is not in demoObjClassSet so it gets dropped; 'car' is kept
    const parsed = parseDemoPath("/g:obj:car:all/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSelectedClasses: ["car"],
    });

    expect(demoPathForState(parsed)).toBe("/g:obj:car/plain/local:///images/dog.jpg");
  });

  it("preserves g:obj:face as the legacy objFace mode", () => {
    const parsed = parseDemoPath("/g:obj:face/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "objFace",
    });
  });

  it("round-trips bare crop obj gravity through the demo path", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "obj" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj");

    const parsed = parseDemoPath(demoPathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj",
    });
  });

  it("round-trips explicit obj:all crop gravity through the demo path", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "obj:all" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj:all");

    const parsed = parseDemoPath(demoPathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj:all",
    });
  });

  it("objGravitySegment helper produces correct URL segments", () => {
    expect(objGravitySegment([])).toBe("g:obj");
    expect(objGravitySegment(["car"])).toBe("g:obj:car");
    expect(objGravitySegment(["car", "dog"])).toBe("g:obj:car:dog");
  });

  // ---- Object gravity: Weighted sub-mode ----

  it("weighted mode with empty selection emits bare g:obj", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "weighted" as const,
      objSelectedClasses: [],
      objWeights: {},
    };

    expect(optionSegments(state)).toEqual(["g:obj"]);
  });

  it("weighted mode with all-equal weights emits compact g:obj form", () => {
    // car=1, dog=1 — uniform, inert → compact g:obj:car:dog
    expect(
      objGravitySegmentFromState({
        ...defaultDemoState,
        objSubMode: "weighted",
        objSelectedClasses: ["car", "dog"],
        objWeights: { car: 1, dog: 1 },
      }),
    ).toBe("g:obj:car:dog");

    // single class, any weight → uniform, compact form
    expect(
      objGravitySegmentFromState({
        ...defaultDemoState,
        objSubMode: "weighted",
        objSelectedClasses: ["car"],
        objWeights: { car: 2 },
      }),
    ).toBe("g:obj:car");
  });

  it("weighted mode with non-uniform weights emits g:objw verbatim (class:1 kept)", () => {
    // car=1, dog=2 — not uniform, car:1 must NOT be dropped
    expect(
      objGravitySegmentFromState({
        ...defaultDemoState,
        objSubMode: "weighted",
        objSelectedClasses: ["car", "dog"],
        objWeights: { car: 1, dog: 2 },
      }),
    ).toBe("g:objw:car:1:dog:2");
  });

  it("weighted mode with all=2 and face=3 emits g:objw:all:2:face:3", () => {
    expect(
      objGravitySegmentFromState({
        ...defaultDemoState,
        objSubMode: "weighted",
        objSelectedClasses: ["all", "face"],
        objWeights: { all: 2, face: 3 },
      }),
    ).toBe("g:objw:all:2:face:3");
  });

  it("g:objw:all:1:face:3 preserves both classes (NOT normalized — different semantics)", () => {
    // g:objw:all:1:face:3 detects ALL objects with face boosted 3×.
    // g:objw:face:3 filters to face only.
    // These are DIFFERENT requests — the demo must NOT rewrite one into the other.
    const parsed = parseDemoPath("/g:objw:all:1:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityMode: "object",
      objSubMode: "weighted",
      objSelectedClasses: expect.arrayContaining(["all", "face"]),
      objWeights: expect.objectContaining({ all: 1, face: 3 }),
    });

    // Serializes back with both all and face (uniform weights → compact obj form,
    // but all:1 face:3 are NOT uniform so → objw verbatim)
    expect(demoPathForState(parsed)).toBe("/g:objw:all:1:face:3/plain/local:///images/dog.jpg");
  });

  it("round-trips g:objw:face:3 (single face weight) through the demo path", () => {
    const parsed = parseDemoPath("/g:objw:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted",
      objSelectedClasses: ["face"],
      objWeights: { face: 3 },
    });

    // Single class with weight 3 → uniform (only one) → compact g:obj:face form
    expect(demoPathForState(parsed)).toBe("/g:obj:face/plain/local:///images/dog.jpg");
  });

  it("round-trips g:objw:all:2:face:3 through the demo path", () => {
    const parsed = parseDemoPath("/g:objw:all:2:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted",
      objWeights: expect.objectContaining({ all: 2, face: 3 }),
    });

    expect(demoPathForState(parsed)).toBe("/g:objw:all:2:face:3/plain/local:///images/dog.jpg");
  });

  it("emits g:objw for object gravity with non-uniform weighted mode", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "weighted" as const,
      objSelectedClasses: ["face", "person"],
      objWeights: { face: 3, person: 1 },
    };

    expect(optionSegments(state)).toEqual(["g:objw:face:3:person:1"]);
    expect(demoPathForState(state)).toBe("/g:objw:face:3:person:1/plain/local:///images/dog.jpg");
  });

  it("rejects invalid objw gravity values in demo routes", () => {
    // bare g:objw (no pairs)
    expect(parseDemoPath("/g:objw/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    // odd arity
    expect(parseDemoPath("/g:objw:face/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    // non-positive weight
    expect(parseDemoPath("/g:objw:face:0/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/g:objw:face:-2/plain/local:///images/dog.jpg")).toEqual(
      defaultDemoState,
    );
    // non-numeric weight
    expect(parseDemoPath("/g:objw:face:bad/plain/local:///images/dog.jpg")).toEqual(
      defaultDemoState,
    );
  });

  it("COCO-80 class list has exactly 80 entries in underscore spelling", () => {
    expect(cocoClasses).toHaveLength(80);
    expect(cocoClasses).toContain("person");
    expect(cocoClasses).toContain("traffic_light");
    expect(cocoClasses).toContain("toothbrush");
    // No space-spelled entries
    expect(cocoClasses.every((c) => !c.includes(" "))).toBe(true);
  });

  it("normalizes focal point coordinates from a picker rectangle", () => {
    expect(
      focalPointFromBounds(150, 75, {
        left: 100,
        top: 50,
        width: 200,
        height: 100,
      }),
    ).toEqual({ x: 0.25, y: 0.25 });
  });

  it("clamps focal point coordinates to the picker rectangle", () => {
    expect(
      focalPointFromBounds(360, 20, {
        left: 100,
        top: 50,
        width: 200,
        height: 100,
      }),
    ).toEqual({ x: 1, y: 0 });
  });

  it("keeps focal point coordinates stable for an unloaded picker rectangle", () => {
    expect(
      focalPointFromBounds(100, 50, {
        left: 100,
        top: 50,
        width: 0,
        height: 0,
      }),
    ).toEqual({ x: 0, y: 0 });
  });

  it("allows crop to use an explicit gravity", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "soea" as const,
      gravity: "ce" as const,
    };

    expect(optionSegments(state)).toEqual([
      "c:5011:7516:soea",
      "rs:fill:640:360:0",
      "g:ce",
      "q:85",
    ]);
  });

  it("builds the crop tool summary from the emitted crop segment", () => {
    expect(cropOptionSegment(defaultDemoState)).toBeNull();

    expect(cropOptionSegment({ ...defaultDemoState, cropEnabled: true })).toBe("c:5011:7516");

    expect(
      cropOptionSegment({
        ...defaultDemoState,
        cropEnabled: true,
        cropWidthUnit: "percent" as const,
        cropWidthPercent: 50,
        cropHeightUnit: "full" as const,
        cropGravity: "soea" as const,
      }),
    ).toBe("c:0.5:0:soea");
  });

  it("emits mixed relative and pixel crop dimensions", () => {
    const state = {
      ...defaultDemoState,
      cropEnabled: true,
      cropWidthUnit: "percent" as const,
      cropWidthPercent: 50,
      cropHeightUnit: "px" as const,
      cropHeight: 240,
    };

    expect(optionSegments(state)).toEqual(["c:0.5:240"]);
  });

  it("emits full crop dimensions as zero per axis", () => {
    const state = {
      ...defaultDemoState,
      cropEnabled: true,
      cropWidthUnit: "full" as const,
      cropHeightUnit: "percent" as const,
      cropHeightPercent: 25,
    };

    expect(optionSegments(state)).toEqual(["c:0:0.25"]);
  });

  it("keeps crop zero exclusive to the full unit", () => {
    expect(cropDimensionSegment("px", 0, 50)).toBe("1");
    expect(cropDimensionSegment("full", 320, 50)).toBe("0");
  });

  it("includes enabled resize extras after the resize segment", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      zoomEnabled: true,
      zoom: 1.5,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 180,
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "z:1.5",
      "dpr:2",
      "mw:320",
      "mh:180",
    ]);
  });

  it("includes enabled resize extras even when resize is disabled", () => {
    const state = {
      ...defaultDemoState,
      zoomEnabled: true,
      zoom: 1.5,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 180,
    };

    expect(optionSegments(state)).toEqual(["z:1.5", "dpr:2", "mw:320", "mh:180"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/z:1.5/dpr:2/mw:320/mh:180/plain/local:///images/dog.jpg",
    );
  });

  it("omits explicit format when format is disabled", () => {
    const state = {
      ...activeDemoState,
      formatEnabled: false,
      format: "png" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("includes explicit format when format is enabled", () => {
    const state = {
      ...activeDemoState,
      formatEnabled: true,
      format: "png" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "f:png", "q:85"]);
  });

  it("omits quality when quality is disabled", () => {
    const state = {
      ...activeDemoState,
      qualityEnabled: false,
      quality: 42,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/g:ce/plain/local:///images/dog.jpg",
    );
  });

  it("includes zero quality when quality is enabled", () => {
    const state = {
      ...activeDemoState,
      qualityEnabled: true,
      quality: 0,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:0"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/g:ce/q:0/plain/local:///images/dog.jpg",
    );
  });

  it("omits top-level gravity when gravity is disabled", () => {
    const state = {
      ...activeDemoState,
      gravityEnabled: false,
      gravity: "sowe" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "q:85"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/q:85/plain/local:///images/dog.jpg",
    );
  });

  it("keeps global gravity when resize is disabled", () => {
    const state = {
      ...activeDemoState,
      resizeEnabled: false,
    };

    expect(optionSegments(state)).toEqual(["g:ce", "q:85"]);
    expect(buildProcessingPath(state)).toBe("/img/_/g:ce/q:85/plain/local:///images/dog.jpg");
  });

  it("emits car with enlarge", () => {
    const state = {
      ...defaultDemoState,
      cropEnabled: true,
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1,
      cropAspectRatioEnlarge: true,
    };
    expect(optionSegments(state)).toContain("car:1:1");
  });

  it("emits car without enlarge", () => {
    const state = {
      ...defaultDemoState,
      cropEnabled: true,
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: false,
    };
    expect(optionSegments(state)).toContain("car:1.5");
  });

  it("does not emit an empty option segment when all tools are disabled", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: false,
      cropEnabled: false,
      gravityEnabled: false,
      formatEnabled: false,
      qualityEnabled: false,
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("shows automatic output as pending until response metadata is available", () => {
    expect(resolvedOutputLabel(defaultDemoState, null)).toBe("auto");
    expect(
      resolvedOutputLabel(defaultDemoState, {
        width: 640,
        height: 480,
        bytes: 10_000,
        contentType: "image/avif",
      }),
    ).toBe("auto -> avif");
    expect(resolvedOutputLabel({ ...defaultDemoState, formatEnabled: true, format: "png" })).toBe(
      "png",
    );
  });

  it("formats the processed image dimensions and encoded byte size", () => {
    expect(
      processedSizeLabel({
        width: 640,
        height: 480,
        bytes: 552_960,
        contentType: "image/jpeg",
      }),
    ).toBe("640 × 480 (540 kB)");
    expect(processedSizeLabel({ width: 300, height: 200, bytes: null, contentType: null })).toBe(
      "300 × 200",
    );
  });
});

describe("demo URL state", () => {
  it("builds a shareable demo route from generated request options", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      formatEnabled: true,
      qualityEnabled: true,
    };

    expect(demoPathForState(state)).toBe(
      "/rs:fill:640:360:0/g:ce/f:jpeg/q:85/plain/local:///images/dog.jpg",
    );
  });

  it("parses a shareable demo route into enabled controls", () => {
    const parsed = parseDemoPath(
      "/rs:fill:640:360:0/g:ce/f:jpeg/q:85/plain/local:///images/dog.jpg",
    );

    expect(parsed).toMatchObject({
      source: "images/dog.jpg",
      resizeEnabled: true,
      resizeMode: "fill",
      width: 640,
      height: 360,
      gravityEnabled: true,
      gravityMode: "anchor",
      gravity: "ce",
      formatEnabled: true,
      format: "jpeg",
      qualityEnabled: true,
      quality: 85,
    });
  });

  it("round-trips trim with threshold only through the demo path", () => {
    const parsed = parseDemoPath("/trim:10/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto",
      trimEqualHor: false,
      trimEqualVer: false,
    });

    expect(demoPathForState(parsed)).toBe("/trim:10/plain/local:///images/dog.jpg");
  });

  it("round-trips trim with color through the demo path", () => {
    const parsed = parseDemoPath("/trim:10:ff00ff/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "color",
      trimColor: "#ff00ff",
    });

    expect(demoPathForState(parsed)).toBe("/trim:10:ff00ff/plain/local:///images/dog.jpg");
  });

  it("round-trips trim with empty color slot and flags through the demo path", () => {
    const parsed = parseDemoPath("/trim:10::1:1/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto",
      trimEqualHor: true,
      trimEqualVer: true,
    });

    expect(demoPathForState(parsed)).toBe("/trim:10::1:1/plain/local:///images/dog.jpg");
  });

  it("round-trips trim short alias (t) through the demo path", () => {
    const parsed = parseDemoPath("/t:15/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 15,
    });

    // Re-emits using the long form "trim:"
    expect(demoPathForState(parsed)).toBe("/trim:15/plain/local:///images/dog.jpg");
  });

  it("rejects invalid trim values in demo routes", () => {
    expect(parseDemoPath("/trim:-1/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/trim:bad/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/trim:10:zzz/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/trim:10:ff00ff:2:0/plain/local:///images/dog.jpg")).toEqual(
      defaultDemoState,
    );
    expect(parseDemoPath("/trim:10:ff00ff:0:2/plain/local:///images/dog.jpg")).toEqual(
      defaultDemoState,
    );
  });

  it("parses crop, orientation, scale, canvas, padding, background, and effects options", () => {
    const parsed = parseDemoPath(
      "/ar:1/fl:0:1/rot:90/c:0.5:0.25:no/z:1.25/dpr:2/mw:320/mh:240/exar:1/pd:1:2:3:4/bg:ffcc00/bga:0.42/bl:2.5/sh:0.7/pix:8/mc:0.5:ffcc00/dt:0.25:112233:ffeecc/br:20/co:-15/sa:35/plain/local:///images/beach.jpg",
    );

    expect(parsed).toMatchObject({
      source: "images/beach.jpg",
      autoRotateEnabled: true,
      flip: "vertical",
      rotate: 90,
      cropEnabled: true,
      cropWidthUnit: "percent",
      cropWidthPercent: 50,
      cropHeightUnit: "percent",
      cropHeightPercent: 25,
      cropGravity: "no",
      zoomEnabled: true,
      zoom: 1.25,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 240,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "ce",
      paddingEnabled: true,
      paddingTop: 1,
      paddingRight: 2,
      paddingBottom: 3,
      paddingLeft: 4,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.42,
      blurEnabled: true,
      blur: 2.5,
      sharpenEnabled: true,
      sharpen: 0.7,
      pixelateEnabled: true,
      pixelate: 8,
      monochromeEnabled: true,
      monochromeIntensity: 0.5,
      monochromeColor: "#ffcc00",
      duotoneEnabled: true,
      duotoneIntensity: 0.25,
      duotoneShadow: "#112233",
      duotoneHighlight: "#ffeecc",
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: -15,
      saturationEnabled: true,
      saturation: 35,
    });
  });

  it("parses long aliases for color effect options", () => {
    expect(
      parseDemoPath("/brightness:20/contrast:-15/saturation:35/plain/local:///images/dog.jpg"),
    ).toMatchObject({
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: -15,
      saturationEnabled: true,
      saturation: 35,
    });
  });

  it("uses duotone defaults for omitted demo route colors", () => {
    expect(parseDemoPath("/dt:0.5:112233/plain/local:///images/dog.jpg")).toMatchObject({
      duotoneEnabled: true,
      duotoneIntensity: 0.5,
      duotoneShadow: "#112233",
      duotoneHighlight: defaultDemoState.duotoneHighlight,
    });

    expect(parseDemoPath("/dt:0.5::ffeecc/plain/local:///images/dog.jpg")).toMatchObject({
      duotoneEnabled: true,
      duotoneIntensity: 0.5,
      duotoneShadow: defaultDemoState.duotoneShadow,
      duotoneHighlight: "#ffeecc",
    });
  });

  it("treats pixelate size one as a demo no-op", () => {
    expect(parseDemoPath("/pix:1/plain/local:///images/dog.jpg")).toEqual({
      ...defaultDemoState,
      pixelateEnabled: false,
      pixelate: defaultDemoState.pixelate,
    });
  });

  it("treats zero-valued effects as demo no-ops", () => {
    expect(parseDemoPath("/bl:0/sh:0/pix:0/br:0/co:0/sa:0/plain/local:///images/dog.jpg")).toEqual({
      ...defaultDemoState,
      blurEnabled: false,
      blur: defaultDemoState.blur,
      sharpenEnabled: false,
      sharpen: defaultDemoState.sharpen,
      pixelateEnabled: false,
      pixelate: defaultDemoState.pixelate,
      monochromeEnabled: false,
      monochromeIntensity: defaultDemoState.monochromeIntensity,
      monochromeColor: defaultDemoState.monochromeColor,
      duotoneEnabled: false,
      duotoneIntensity: defaultDemoState.duotoneIntensity,
      duotoneShadow: defaultDemoState.duotoneShadow,
      duotoneHighlight: defaultDemoState.duotoneHighlight,
      brightnessEnabled: false,
      brightness: defaultDemoState.brightness,
      contrastEnabled: false,
      contrast: defaultDemoState.contrast,
      saturationEnabled: false,
      saturation: defaultDemoState.saturation,
    });
  });

  it("expands accordions that contain active URL state", () => {
    const state = parseDemoPath("/ar:1/z:1.5/br:20/plain/local:///images/dog.jpg");

    expect(expandedToolboxesForState(state)).toEqual({
      effectsOpen: true,
      orientationOpen: true,
      scaleOptionsOpen: true,
      requestOpen: true,
    });
  });

  it("parses car with and without enlarge", () => {
    expect(parseDemoPath("/car:1.5/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: false,
    });

    expect(parseDemoPath("/car:1.5:1/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: true,
    });

    expect(parseDemoPath("/car:2:0/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 2,
      cropAspectRatioEnlarge: false,
    });
  });

  it("round-trips a car-only path through parse and emit", () => {
    const parsed = parseDemoPath("/car:1.5:1/plain/local:///images/dog.jpg");

    expect(parsed).not.toBeNull();
    // car must survive serialization even though cropEnabled stays false.
    expect(optionSegments(parsed as DemoState)).toContain("car:1.5:1");
  });

  it("rejects invalid car values in demo routes", () => {
    expect(parseDemoPath("/car:-1/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/car:bad/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/car:1.5:bad/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/car:1:2:3/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
  });

  it("falls back to defaults for invalid demo routes", () => {
    expect(parseDemoPath("/not-supported/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/rs:fill:640:360:0/plain/images/dog.jpg")).toEqual(defaultDemoState);
    expect(
      parseDemoPath("/not-a-valid-option/rs:fill:640:360:0/plain/local:///images/dog.jpg"),
    ).toEqual(defaultDemoState);
  });

  it("rejects invalid quality values in demo routes", () => {
    expect(parseDemoPath("/q:-1/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/q:101/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/q:85.5/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
  });

  it("rejects invalid color effect values in demo routes", () => {
    expect(parseDemoPath("/br:-101/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/co:101/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/sa:100.5/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/mc:1.1/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/dt:0.5:zzz/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
  });

  it("emits nothing for default metadata and color-profile state (all true)", () => {
    expect(optionSegments(defaultDemoState)).toEqual([]);
  });

  it("emits sm:0 when stripMetadata is false", () => {
    const state = { ...defaultDemoState, stripMetadata: false, keepCopyright: false };

    expect(optionSegments(state)).toContain("sm:0");
    expect(optionSegments(state)).not.toContain("kcr:0");
  });

  it("emits kcr:0 when stripMetadata is true but keepCopyright is false", () => {
    const state = { ...defaultDemoState, stripMetadata: true, keepCopyright: false };

    expect(optionSegments(state)).toContain("kcr:0");
    expect(optionSegments(state)).not.toContain("sm:0");
  });

  it("does not emit kcr when stripMetadata is false (canonical omission)", () => {
    const state = { ...defaultDemoState, stripMetadata: false, keepCopyright: true };

    const segments = optionSegments(state);

    expect(segments).toContain("sm:0");
    expect(segments).not.toContain("kcr:0");
    expect(segments).not.toContain("kcr:1");
  });

  it("emits scp:0 when stripColorProfile is false", () => {
    const state = { ...defaultDemoState, stripColorProfile: false };

    expect(optionSegments(state)).toContain("scp:0");
  });

  it("round-trips sm:0 through parse and emit", () => {
    const parsed = parseDemoPath("/sm:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripMetadata: false, keepCopyright: false });
    expect(optionSegments(parsed)).toContain("sm:0");
    expect(optionSegments(parsed)).not.toContain("kcr:0");
  });

  it("round-trips kcr:0 through parse and emit", () => {
    const parsed = parseDemoPath("/kcr:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripMetadata: true, keepCopyright: false });
    expect(optionSegments(parsed)).toContain("kcr:0");
    expect(optionSegments(parsed)).not.toContain("sm:0");
  });

  it("round-trips scp:0 through parse and emit", () => {
    const parsed = parseDemoPath("/scp:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripColorProfile: false });
    expect(optionSegments(parsed)).toContain("scp:0");
  });

  it("omits cp for the default (none) color-profile state", () => {
    expect(optionSegments(defaultDemoState)).not.toContain("cp:none");
    expect(optionSegments(defaultDemoState).some((seg) => seg.startsWith("cp:"))).toBe(false);
  });

  it("emits cp:<target> for non-none color profiles", () => {
    expect(optionSegments({ ...defaultDemoState, colorProfile: "srgb" })).toContain("cp:srgb");
    expect(optionSegments({ ...defaultDemoState, colorProfile: "display-p3" })).toContain(
      "cp:display-p3",
    );
    expect(optionSegments({ ...defaultDemoState, colorProfile: "adobe-rgb" })).toContain(
      "cp:adobe-rgb",
    );
  });

  it("round-trips cp targets through parse and emit", () => {
    const parsed = parseDemoPath("/cp:display-p3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ colorProfile: "display-p3" });
    expect(optionSegments(parsed)).toContain("cp:display-p3");
  });

  it("accepts the icc alias and canonicalizes color-profile aliases", () => {
    expect(parseDemoPath("/icc:srgb/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "srgb",
    });
    expect(parseDemoPath("/cp:p3/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "display-p3",
    });
    expect(parseDemoPath("/cp:adobergb/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "adobe-rgb",
    });
  });

  it("rejects unknown cp values in demo routes", () => {
    expect(parseDemoPath("/cp:cmyk/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/cp:/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/cp:srgb:extra/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
  });

  it("normalizes keepCopyright to false when sm:0 is parsed without kcr", () => {
    const parsedSmOnly = parseDemoPath("/sm:0/plain/local:///images/dog.jpg");

    expect(parsedSmOnly).toMatchObject({ stripMetadata: false, keepCopyright: false });
  });

  it("normalizes keepCopyright to false regardless of sm/kcr segment order", () => {
    const kcrThenSm = parseDemoPath("/kcr:1/sm:0/plain/local:///images/dog.jpg");
    const smThenKcr = parseDemoPath("/sm:0/kcr:1/plain/local:///images/dog.jpg");

    expect(kcrThenSm).toMatchObject({ stripMetadata: false, keepCopyright: false });
    expect(smThenKcr).toMatchObject({ stripMetadata: false, keepCopyright: false });
  });

  it("accepts boolean aliases for sm, kcr, and scp", () => {
    expect(parseDemoPath("/sm:1/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseDemoPath("/sm:t/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseDemoPath("/sm:true/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseDemoPath("/sm:f/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: false,
    });
    expect(parseDemoPath("/sm:false/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: false,
    });
    expect(parseDemoPath("/kcr:0/plain/local:///images/dog.jpg")).toMatchObject({
      keepCopyright: false,
    });
    expect(parseDemoPath("/scp:f/plain/local:///images/dog.jpg")).toMatchObject({
      stripColorProfile: false,
    });
  });

  it("rejects invalid sm/kcr/scp values in demo routes", () => {
    expect(parseDemoPath("/sm:yes/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/kcr:2/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/scp:/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
    expect(parseDemoPath("/sm:0:extra/plain/local:///images/dog.jpg")).toEqual(defaultDemoState);
  });

  it("resets processing options while keeping source and signature settings", () => {
    const reset = resetDemoSettings({
      ...defaultDemoState,
      source: "images/beach.jpg",
      signatureMode: "signed",
      signatureKey: "abcd",
      signatureSalt: "1234",
      resizeEnabled: true,
      gravityEnabled: true,
      qualityEnabled: true,
      cropEnabled: true,
      cropWidth: 24,
      cropHeight: 24,
    });

    expect(reset).toMatchObject({
      ...defaultDemoState,
      source: "images/beach.jpg",
      signatureMode: "signed",
      signatureKey: "abcd",
      signatureSalt: "1234",
      cropWidth: cropPixelLimit("images/beach.jpg", "width").max,
      cropHeight: cropPixelLimit("images/beach.jpg", "height").max,
    });
    expect(optionSegments(reset)).toEqual([]);
    expect(demoPathForState(reset)).toBe("/plain/local:///images/beach.jpg");
  });
});
