import { describe, expect, it } from "vitest";

import {
  buildProcessingPath,
  defaultDemoState,
  processedSizeLabel,
  optionSegments,
  resolvedOutputLabel
} from "./processing-path";

describe("processing path generation", () => {
  it("builds the default SimpleServer-compatible processing path", () => {
    expect(buildProcessingPath(defaultDemoState)).toBe(
      "/_/rs:fill:640:360:0/g:ce/q:85/plain/images/dog.jpg"
    );
  });

  it("includes crop options before resize options when crop is enabled", () => {
    const state = {
      ...defaultDemoState,
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
      ...defaultDemoState,
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
      ...defaultDemoState,
      gravity: "sowe" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:sowe", "q:85"]);
  });

  it("allows crop to use an explicit gravity", () => {
    const state = {
      ...defaultDemoState,
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

  it("omits explicit format when format is disabled", () => {
    const state = {
      ...defaultDemoState,
      formatEnabled: false,
      format: "png" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("includes explicit format when format is enabled", () => {
    const state = {
      ...defaultDemoState,
      formatEnabled: true,
      format: "png" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "f:png", "q:85"]);
  });

  it("omits quality when quality is disabled", () => {
    const state = {
      ...defaultDemoState,
      qualityEnabled: false,
      quality: 42
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/g:ce/plain/images/dog.jpg");
  });

  it("omits top-level gravity when gravity is disabled", () => {
    const state = {
      ...defaultDemoState,
      gravityEnabled: false,
      gravity: "sowe" as const
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "q:85"]);
    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/q:85/plain/images/dog.jpg");
  });

  it("omits resize and gravity options when resize is disabled", () => {
    const state = {
      ...defaultDemoState,
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
    expect(resolvedOutputLabel({ ...defaultDemoState, format: "png" })).toBe("png");
  });

  it("formats the processed image dimensions and encoded byte size", () => {
    expect(processedSizeLabel({ width: 640, height: 480, bytes: 552_960 })).toBe(
      "640 × 480 (540 kB)"
    );
    expect(processedSizeLabel({ width: 300, height: 200, bytes: null })).toBe("300 × 200");
  });
});
