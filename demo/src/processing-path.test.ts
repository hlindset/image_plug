import { describe, expect, it } from "vitest";

import {
  buildProcessingPath,
  defaultDemoState,
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

  it("omits explicit format and quality when the controls request automatic output", () => {
    const state = {
      ...defaultDemoState,
      format: "auto" as const,
      quality: 0
    };

    expect(buildProcessingPath(state)).toBe("/_/rs:fill:640:360:0/g:ce/plain/images/dog.jpg");
  });

  it("omits resize and gravity options when resize is disabled", () => {
    const state = {
      ...defaultDemoState,
      resizeEnabled: false
    };

    expect(optionSegments(state)).toEqual(["q:85"]);
    expect(buildProcessingPath(state)).toBe("/_/q:85/plain/images/dog.jpg");
  });

  it("shows the negotiated output label for automatic formats", () => {
    expect(resolvedOutputLabel(defaultDemoState)).toBe("auto -> webp");
    expect(resolvedOutputLabel({ ...defaultDemoState, format: "png" })).toBe("png");
  });
});
