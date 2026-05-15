import App from "./App.svelte";
import "./styles.css";
import { mount } from "svelte";

const target = document.getElementById("demo-app");

if (!(target instanceof HTMLElement)) {
  throw new Error("Demo root element is missing");
}

mount(App, { target });
