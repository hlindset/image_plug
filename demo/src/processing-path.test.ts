import { describe, expect, it } from "vitest";

import { buildProcessingPath, defaultDemoState, optionSegments } from "./processing-path";

describe("processing path generation", () => {
  it("builds the default SimpleServer-compatible processing path", () => {
    expect(buildProcessingPath(defaultDemoState)).toBe(
      "/_/rs:fill:1160:540:0/g:ce/f:webp/q:82/plain/images/dog.jpg"
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
      "rs:fill:1160:540:0",
      "g:ce",
      "f:webp",
      "q:82"
    ]);
  });

  it("omits explicit format and quality when the controls request automatic output", () => {
    const state = {
      ...defaultDemoState,
      format: "auto" as const,
      quality: 0
    };

    expect(buildProcessingPath(state)).toBe("/_/rs:fill:1160:540:0/g:ce/plain/images/dog.jpg");
  });
});
