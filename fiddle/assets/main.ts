import App from "./App.svelte";
import "./styles.css";
import { applyThemeMode, readStoredThemeMode } from "./theme";
import { mount } from "svelte";

const target = document.getElementById("fiddle-app");

if (!(target instanceof HTMLElement)) {
  throw new Error("Fiddle root element is missing");
}

applyThemeMode(readStoredThemeMode());
mount(App, { target });
