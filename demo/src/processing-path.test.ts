import { describe, expect, it } from "vitest";

import {
  buildProcessingPath,
  defaultDemoState,
  focalPointFromBounds,
  processedSizeLabel,
  optionSegments,
  resolvedOutputLabel
} from "./processing-path";

const activeDemoState = {
  ...defaultDemoState,
  resizeEnabled: true,
  gravityEnabled: true,
  qualityEnabled: true
};

describe("processing path generation", () => {
  it("builds the default SimpleServer-compatible processing path", () => {
    expect(optionSegments(defaultDemoState)).toEqual([]);
    expect(buildProcessingPath(defaultDemoState)).toBe("/_/plain/images/dog.jpg");
  });

  it("keeps jpeg selected as the default explicit format", () => {
    expect(defaultDemoState.format).toBe("jpeg");
  });

  it("includes auto rotate as an explicit orientation option", () => {
    const state = {
      ...defaultDemoState,
      autoRotateEnabled: true
    };

    expect(optionSegments(state)).toEqual(["ar:1"]);
    expect(buildProcessingPath(state)).toBe("/_/ar:1/plain/images/dog.jpg");
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

  it("includes canvas extend after resize when enabled", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      canvasEnabled: true,
      canvasMode: "extend" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "ex:1"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/ex:1/plain/images/dog.jpg");
  });

  it("includes extend aspect ratio when canvas aspect ratio mode is enabled", () => {
    const state = {
      ...defaultDemoState,
      canvasEnabled: true,
      canvasMode: "aspectRatio" as const,
      extendAspectWidth: 16,
      extendAspectHeight: 9
    };

    expect(optionSegments(state)).toEqual(["exar:16:9"]);
    expect(buildProcessingPath(state)).toBe("/_/exar:16:9/plain/images/dog.jpg");
  });

  it("includes explicit four-sided padding after canvas options", () => {
    const state = {
      ...defaultDemoState,
      canvasEnabled: true,
      canvasMode: "extend" as const,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 16,
      paddingBottom: 24,
      paddingLeft: 32
    };

    expect(optionSegments(state)).toEqual(["ex:1", "pd:8:16:24:32"]);
    expect(buildProcessingPath(state)).toBe("/_/ex:1/pd:8:16:24:32/plain/images/dog.jpg");
  });

  it("includes background color and optional alpha after padding", () => {
    const state = {
      ...defaultDemoState,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 8,
      paddingBottom: 8,
      paddingLeft: 8,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlphaEnabled: true,
      backgroundAlpha: 0.5
    };

    expect(optionSegments(state)).toEqual(["pd:8:8:8:8", "bg:ffcc00", "bga:0.5"]);
    expect(buildProcessingPath(state)).toBe("/_/pd:8:8:8:8/bg:ffcc00/bga:0.5/plain/images/dog.jpg");
  });

  it("includes crop options before resize options when crop is enabled", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropWidth: 320,
      cropHeight: 240
    };

    expect(optionSegments(state)).toEqual([
      "c:320:240",
      "rs:fill:640:360:0",
      "g:ce",
      "q:85"
    ]);
  });

  it("does not write inherited crop gravity into the crop segment", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "inherit" as const,
      gravity: "nowe" as const
    };

    expect(optionSegments(state)).toEqual([
      "c:640:420",
      "rs:fill:640:360:0",
      "g:nowe",
      "q:85"
    ]);
  });

  it("uses shared gravity as the top-level gravity option", () => {
    const state = {
      ...activeDemoState,
      gravity: "sowe" as const
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
      gravityFocalY: 0.75
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:fp:0.25:0.75"]);
  });

  it("includes offset global gravity", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "offset" as const,
      gravity: "soea" as const,
      gravityOffsetX: 12,
      gravityOffsetY: -0.25
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:soea:12:-0.25"]);
  });

  it("normalizes focal point coordinates from a picker rectangle", () => {
    expect(
      focalPointFromBounds(150, 75, {
        left: 100,
        top: 50,
        width: 200,
        height: 100
      })
    ).toEqual({ x: 0.25, y: 0.25 });
  });

  it("clamps focal point coordinates to the picker rectangle", () => {
    expect(
      focalPointFromBounds(360, 20, {
        left: 100,
        top: 50,
        width: 200,
        height: 100
      })
    ).toEqual({ x: 1, y: 0 });
  });

  it("keeps focal point coordinates stable for an unloaded picker rectangle", () => {
    expect(
      focalPointFromBounds(100, 50, {
        left: 100,
        top: 50,
        width: 0,
        height: 0
      })
    ).toEqual({ x: 0, y: 0 });
  });

  it("allows crop to use an explicit gravity", () => {
    const state = {
      ...activeDemoState,
      cropEnabled: true,
      cropGravity: "soea" as const,
      gravity: "ce" as const
    };

    expect(optionSegments(state)).toEqual([
      "c:640:420:soea",
      "rs:fill:640:360:0",
      "g:ce",
      "q:85"
    ]);
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
      minHeight: 180
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "z:1.5",
      "dpr:2",
      "mw:320",
      "mh:180"
    ]);
  });

  it("omits resize extras when resize is disabled", () => {
    const state = {
      ...defaultDemoState,
      zoomEnabled: true,
      zoom: 1.5,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 180
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/_/plain/images/dog.jpg");
  });

  it("omits explicit format when format is disabled", () => {
    const state = {
      ...activeDemoState,
      formatEnabled: false,
      format: "png" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("includes explicit format when format is enabled", () => {
    const state = {
      ...activeDemoState,
      formatEnabled: true,
      format: "png" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "f:png", "q:85"]);
  });

  it("omits quality when quality is disabled", () => {
    const state = {
      ...activeDemoState,
      qualityEnabled: false,
      quality: 42
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/g:ce/plain/images/dog.jpg");
  });

  it("includes zero quality when quality is enabled", () => {
    const state = {
      ...activeDemoState,
      qualityEnabled: true,
      quality: 0
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:0"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/g:ce/q:0/plain/images/dog.jpg");
  });

  it("omits top-level gravity when gravity is disabled", () => {
    const state = {
      ...activeDemoState,
      gravityEnabled: false,
      gravity: "sowe" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "q:85"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/q:85/plain/images/dog.jpg");
  });

  it("omits resize and gravity options when resize is disabled", () => {
    const state = {
      ...activeDemoState,
      resizeEnabled: false
    };

    expect(optionSegments(state)).toEqual(["q:85"]);
    expect(buildProcessingPath(state)).toBe("/_/q:85/plain/images/dog.jpg");
  });

  it("does not emit an empty option segment when all tools are disabled", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: false,
      cropEnabled: false,
      gravityEnabled: false,
      formatEnabled: false,
      qualityEnabled: false
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/_/plain/images/dog.jpg");
  });

  it("shows the negotiated output label for automatic formats", () => {
    expect(resolvedOutputLabel(defaultDemoState)).toBe("auto -> webp");
    expect(resolvedOutputLabel({ ...defaultDemoState, formatEnabled: true, format: "png" })).toBe("png");
  });

  it("formats the processed image dimensions and encoded byte size", () => {
    expect(processedSizeLabel({ width: 640, height: 480, bytes: 552_960 })).toBe(
      "640 × 480 (540 kB)"
    );
    expect(processedSizeLabel({ width: 300, height: 200, bytes: null })).toBe("300 × 200");
  });
});
