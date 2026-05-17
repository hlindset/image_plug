export const themeModes = ["light", "dark", "system"] as const;

export type ThemeMode = (typeof themeModes)[number];

export const themeStorageKey = "image-plug-demo-theme";

export function storedThemeMode(value: string | null): ThemeMode {
  return themeModes.includes(value as ThemeMode) ? (value as ThemeMode) : "system";
}

export function readStoredThemeMode(storage: Pick<Storage, "getItem"> = localStorage): ThemeMode {
  try {
    return storedThemeMode(storage.getItem(themeStorageKey));
  } catch {
    return "system";
  }
}

export function persistThemeMode(
  mode: ThemeMode,
  storage: Pick<Storage, "setItem"> = localStorage,
): void {
  try {
    storage.setItem(themeStorageKey, mode);
  } catch {
    // Theme persistence is cosmetic; private browsing storage failures should not break the demo.
  }
}

export function applyThemeMode(
  mode: ThemeMode,
  root: Pick<HTMLElement, "dataset"> = document.documentElement,
): void {
  root.dataset.theme = mode;
}
