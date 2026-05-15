const state = {
  signature: "_",
  source: "images/dog.jpg",
  resizeMode: "fill",
  width: 1160,
  height: 540,
  gravity: "ce",
  enlarge: false,
  cropEnabled: false,
  cropWidth: 640,
  cropHeight: 420,
  format: "webp",
  quality: 82
};

const elements = {
  controls: document.querySelectorAll("[data-option]"),
  numberInputs: document.querySelectorAll("[data-number-for]"),
  panels: document.querySelectorAll("[data-panel]"),
  panelTargets: document.querySelectorAll("[data-panel-target]"),
  previewImage: document.querySelector("[data-preview-image]"),
  previewFragment: document.querySelector("[data-preview-fragment]"),
  generatedUrl: document.querySelector("[data-generated-url]"),
  openUrl: document.querySelector("[data-open-url]"),
  copyUrl: document.querySelector("[data-copy-url]")
};

function optionSegments(currentState) {
  const resize = [
    "rs",
    currentState.resizeMode,
    currentState.width,
    currentState.height,
    currentState.enlarge ? 1 : 0
  ].join(":");

  const segments = [resize, `g:${currentState.gravity}`];

  if (currentState.cropEnabled) {
    segments.unshift(`c:${currentState.cropWidth}:${currentState.cropHeight}`);
  }

  if (currentState.format !== "auto") {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.quality > 0) {
    segments.push(`q:${currentState.quality}`);
  }

  return segments;
}

function buildProcessingPath(currentState) {
  const options = optionSegments(currentState).join("/");

  return `/${currentState.signature}/${options}/plain/${currentState.source}`;
}

function readControlValue(control) {
  if (control.type === "checkbox") {
    return control.checked;
  }

  if (control.type === "range") {
    return Number(control.value);
  }

  return control.value;
}

function clampNumber(value, input) {
  const min = Number(input.min);
  const max = Number(input.max);

  return Math.min(Math.max(value, min), max);
}

function syncControl(control) {
  const key = control.dataset.option;
  state[key] = readControlValue(control);
  render();
}

function syncNumberInput(input, clamp = false) {
  const key = input.dataset.numberFor;
  const value = input.valueAsNumber;

  if (Number.isNaN(value)) {
    return;
  }

  const nextValue = clamp ? clampNumber(value, input) : value;
  const range = document.querySelector(`[data-option="${key}"]`);

  state[key] = nextValue;
  range.value = nextValue;
  render();
}

function renderNumberInputs() {
  for (const input of elements.numberInputs) {
    input.value = state[input.dataset.numberFor];
  }
}

function render() {
  const path = buildProcessingPath(state);
  const fragment = optionSegments(state).join("/");

  renderNumberInputs();

  elements.previewImage.src = path;
  elements.previewFragment.textContent = fragment;
  elements.generatedUrl.textContent = path;
  elements.openUrl.href = path;
}

function showPanel(panelName) {
  for (const panel of elements.panels) {
    panel.classList.toggle("is-active", panel.dataset.panel === panelName);
  }

  for (const target of elements.panelTargets) {
    target.classList.toggle("is-active", target.dataset.panelTarget === panelName);
  }
}

async function copyGeneratedUrl() {
  const path = elements.generatedUrl.textContent;
  const absoluteUrl = new URL(path, window.location.origin).toString();

  await navigator.clipboard.writeText(absoluteUrl);

  elements.copyUrl.textContent = "Copied";
  window.setTimeout(() => {
    elements.copyUrl.textContent = "Copy URL";
  }, 1200);
}

for (const control of elements.controls) {
  control.addEventListener("input", () => syncControl(control));
  control.addEventListener("change", () => syncControl(control));
}

for (const input of elements.numberInputs) {
  input.addEventListener("focus", () => input.select());
  input.addEventListener("input", () => syncNumberInput(input));
  input.addEventListener("change", () => syncNumberInput(input, true));
}

for (const target of elements.panelTargets) {
  target.addEventListener("click", () => showPanel(target.dataset.panelTarget));
}

elements.copyUrl.addEventListener("click", () => {
  copyGeneratedUrl().catch(() => {
    elements.copyUrl.textContent = "Copy failed";
  });
});

render();
