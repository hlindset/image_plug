import { describe, expect, it } from "vitest";

import { sampleImages } from "virtual:sample-images";

describe("sample image virtual module", () => {
  it("lists demo images with compile-time metadata", () => {
    expect(sampleImages).toEqual([
      {
        path: "images/cat-300.jpg",
        label: "cat-300.jpg",
        width: 300,
        height: 188,
      },
      {
        path: "images/dog.jpg",
        label: "dog.jpg",
        width: 5011,
        height: 7516,
      },
    ]);
  });
});
