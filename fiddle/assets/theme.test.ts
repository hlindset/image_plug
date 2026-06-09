import { describe, expect, it } from "vitest";

import { storedThemeMode, themeModes } from "./theme";

describe("theme mode", () => {
  it("supports light, dark, and system modes", () => {
    expect(themeModes).toEqual(["light", "dark", "system"]);
  });

  it("defaults unknown stored values to system", () => {
    expect(storedThemeMode(null)).toBe("system");
    expect(storedThemeMode("dark")).toBe("dark");
    expect(storedThemeMode("high-contrast")).toBe("system");
  });
});
