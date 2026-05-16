<script lang="ts">
  import { Switch } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import {
    buildProcessingPath,
    defaultDemoState,
    focalPointFromBounds,
    gravitySegment,
    processedSizeLabel,
    resolvedOutputLabel,
    type DemoState,
    type ProcessedImageMetadata
  } from "./processing-path";

  let copyLabel = "Copy URL";
  let drawerOpen = false;
  let state: DemoState = { ...defaultDemoState };
  let processedMetadata: ProcessedImageMetadata | null = null;
  let metadataRequestId = 0;
  let focalPickerSurface: HTMLSpanElement | null = null;

  $: path = buildProcessingPath(state);
  $: previewParameters = path.replace(/^\/(?:_|unsafe)\//, "");
  $: outputLabel = resolvedOutputLabel(state);
  $: sizeLabel = processedSizeLabel(processedMetadata);
  $: orientationSummary =
    [
      state.autoRotateEnabled ? "ar:1" : null,
      flipSegment(state.flip),
      state.rotate === 0 ? null : `rot:${state.rotate}`
    ]
      .filter(Boolean)
      .join("/") || "Off";
  $: resizeSummary = state.resizeEnabled
    ? [
        "rs",
        state.resizeMode,
        state.width,
        state.height,
        state.enlarge ? 1 : 0,
        state.resizeExtendEnabled ? 1 : null
      ]
        .filter((value) => value !== null)
        .join(":")
    : "Off";
  $: aspectCanvasSummary = state.aspectCanvasEnabled
    ? `exar:${state.extendAspectWidth}:${state.extendAspectHeight}`
    : "Off";
  $: paddingSummary = state.paddingEnabled
    ? `pd:${state.paddingTop}:${state.paddingRight}:${state.paddingBottom}:${state.paddingLeft}`
    : "Off";
  $: backgroundSummary = state.backgroundEnabled
    ? `bg:${state.backgroundColor.replace(/^#/, "")}${
        state.backgroundAlphaEnabled ? `/bga:${state.backgroundAlpha}` : ""
      }`
    : "Off";
  $: resizeExtras = [
    state.zoomEnabled ? `z:${state.zoom}` : null,
    state.dprEnabled ? `dpr:${state.dpr}` : null,
    state.minWidthEnabled ? `mw:${state.minWidth}` : null,
    state.minHeightEnabled ? `mh:${state.minHeight}` : null
  ]
    .filter(Boolean)
    .join("/");

  function flipSegment(flip: DemoState["flip"]): string | null {
    if (flip === "horizontal") {
      return "fl:1";
    }

    if (flip === "vertical") {
      return "fl:0:1";
    }

    if (flip === "both") {
      return "fl";
    }

    return null;
  }

  async function updateProcessedMetadata(event: Event): Promise<void> {
    const image = event.currentTarget;

    if (!(image instanceof HTMLImageElement)) {
      return;
    }

    const requestId = ++metadataRequestId;
    const imagePath = image.currentSrc || image.src;
    const dimensions = {
      width: image.naturalWidth,
      height: image.naturalHeight
    };

    processedMetadata = { ...dimensions, bytes: null };

    try {
      const response = await fetch(imagePath, { cache: "force-cache" });
      const blob = await response.blob();

      if (requestId === metadataRequestId) {
        processedMetadata = { ...dimensions, bytes: blob.size };
      }
    } catch {
      if (requestId === metadataRequestId) {
        processedMetadata = { ...dimensions, bytes: null };
      }
    }
  }

  async function copyGeneratedUrl(): Promise<void> {
    const absoluteUrl = new URL(path, window.location.origin).toString();

    await navigator.clipboard.writeText(absoluteUrl);
    copyLabel = "Copied";
    window.setTimeout(() => {
      copyLabel = "Copy URL";
    }, 1200);
  }

  function copyUrl(): void {
    copyGeneratedUrl().catch(() => {
      copyLabel = "Copy failed";
    });
  }

  function updateFocalPoint(event: MouseEvent | PointerEvent): void {
    if (focalPickerSurface === null) {
      return;
    }

    const focalPoint = focalPointFromBounds(
      event.clientX,
      event.clientY,
      focalPickerSurface.getBoundingClientRect()
    );

    state.gravityFocalX = focalPoint.x;
    state.gravityFocalY = focalPoint.y;
  }

  function startFocalPointDrag(event: PointerEvent): void {
    const target = event.currentTarget;

    if (target instanceof HTMLElement) {
      target.setPointerCapture(event.pointerId);
    }

    updateFocalPoint(event);
  }

  function dragFocalPoint(event: PointerEvent): void {
    if (event.buttons !== 1) {
      return;
    }

    updateFocalPoint(event);
  }
</script>

<main class="fiddle-shell">
  <button
    class="mobile-scrim"
    class:is-open={drawerOpen}
    type="button"
    aria-label="Close tools"
    onclick={() => (drawerOpen = false)}
  ></button>

  <aside class="tools-sidebar" class:is-open={drawerOpen} aria-label="Processing controls">
    <div class="drawer-topbar">
      <strong>Tools</strong>
      <button
        class="icon-button"
        type="button"
        aria-label="Close tools"
        onclick={() => (drawerOpen = false)}
      >
        ×
      </button>
    </div>

    <div class="tool-stack">
      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Orientation</h2>
            <p>{orientationSummary}</p>
          </div>
        </div>

        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={state.autoRotateEnabled}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Auto rotate</span>
        </label>

        <label class="field">
          <span>Flip</span>
          <select bind:value={state.flip}>
            <option value="none">none</option>
            <option value="horizontal">horizontal</option>
            <option value="vertical">vertical</option>
            <option value="both">both</option>
          </select>
        </label>

        <label class="field">
          <span>Rotate</span>
          <select bind:value={state.rotate}>
            <option value={0}>none</option>
            <option value={90}>90°</option>
            <option value={180}>180°</option>
            <option value={270}>270°</option>
          </select>
        </label>
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Background</h2>
            <p>{backgroundSummary}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable background"
            bind:checked={state.backgroundEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.backgroundEnabled}
          <label class="field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={state.backgroundColor} />
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.backgroundAlphaEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Alpha</span>
          </label>

          {#if state.backgroundAlphaEnabled}
            <RangeNumber
              label="Alpha"
              bind:value={state.backgroundAlpha}
              min={0.1}
              max={1}
              step={0.1}
            />
          {/if}
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Padding</h2>
            <p>{paddingSummary}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable padding"
            bind:checked={state.paddingEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.paddingEnabled}
          <RangeNumber label="Top" bind:value={state.paddingTop} min={0} max={240} step={1} />
          <RangeNumber label="Right" bind:value={state.paddingRight} min={0} max={240} step={1} />
          <RangeNumber label="Bottom" bind:value={state.paddingBottom} min={0} max={240} step={1} />
          <RangeNumber label="Left" bind:value={state.paddingLeft} min={0} max={240} step={1} />
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Resize</h2>
            <p>{resizeSummary}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable resize"
            bind:checked={state.resizeEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.resizeEnabled}
          <RangeNumber label="Width" bind:value={state.width} min={0} max={1600} step={1} />
          <RangeNumber label="Height" bind:value={state.height} min={0} max={1000} step={1} />

          <label class="field">
            <span>Type</span>
            <select bind:value={state.resizeMode}>
              <option value="fit">fit</option>
              <option value="fill">fill</option>
              <option value="fill-down">fill-down</option>
              <option value="force">force</option>
              <option value="auto">auto</option>
            </select>
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.enlarge}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Allow enlargement</span>
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.resizeExtendEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Extend result</span>
          </label>
        {/if}

        <div class="tool-subgroup">
          <div class="subgroup-heading">
            <span>Scale options</span>
            <code>{resizeExtras || "none"}</code>
          </div>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.zoomEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Zoom</span>
          </label>
          {#if state.zoomEnabled}
            <RangeNumber label="Zoom" bind:value={state.zoom} min={0.1} max={4} step={0.1} />
          {/if}

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.dprEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>DPR</span>
          </label>
          {#if state.dprEnabled}
            <RangeNumber label="DPR" bind:value={state.dpr} min={0.1} max={4} step={0.1} />
          {/if}

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.minWidthEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Minimum width</span>
          </label>
          {#if state.minWidthEnabled}
            <RangeNumber label="Min width" bind:value={state.minWidth} min={0} max={1600} step={1} />
          {/if}

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.minHeightEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Minimum height</span>
          </label>
          {#if state.minHeightEnabled}
            <RangeNumber label="Min height" bind:value={state.minHeight} min={0} max={1000} step={1} />
          {/if}
        </div>
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Aspect canvas</h2>
            <p>{aspectCanvasSummary}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable aspect canvas"
            bind:checked={state.aspectCanvasEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.aspectCanvasEnabled}
          <RangeNumber
            label="Ratio width"
            bind:value={state.extendAspectWidth}
            min={1}
            max={32}
            step={1}
          />
          <RangeNumber
            label="Ratio height"
            bind:value={state.extendAspectHeight}
            min={1}
            max={32}
            step={1}
          />
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Crop</h2>
            <p>{state.cropEnabled ? `c:${state.cropWidth}:${state.cropHeight}` : "Off"}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable crop"
            bind:checked={state.cropEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.cropEnabled}
          <RangeNumber label="Crop width" bind:value={state.cropWidth} min={80} max={1200} step={1} />
          <RangeNumber label="Crop height" bind:value={state.cropHeight} min={80} max={900} step={1} />

          <label class="field">
            <span>Gravity</span>
            <select bind:value={state.cropGravity}>
              <option value="inherit">&lt;inherit&gt;</option>
              <option value="ce">center</option>
              <option value="no">north</option>
              <option value="so">south</option>
              <option value="ea">east</option>
              <option value="we">west</option>
              <option value="noea">north east</option>
              <option value="nowe">north west</option>
              <option value="soea">south east</option>
              <option value="sowe">south west</option>
            </select>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Gravity</h2>
            <p>{state.gravityEnabled ? gravitySegment(state) : "Off"}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable gravity"
            bind:checked={state.gravityEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.gravityEnabled}
          <label class="field">
            <span>Mode</span>
            <select bind:value={state.gravityMode}>
              <option value="anchor">anchor</option>
              <option value="focalPoint">focal point</option>
              <option value="offset">anchor + offset</option>
            </select>
          </label>

          {#if state.gravityMode !== "focalPoint"}
            <label class="field">
              <span>Anchor</span>
              <select bind:value={state.gravity}>
                <option value="ce">center</option>
                <option value="no">north</option>
                <option value="so">south</option>
                <option value="ea">east</option>
                <option value="we">west</option>
                <option value="noea">north east</option>
                <option value="nowe">north west</option>
                <option value="soea">south east</option>
                <option value="sowe">south west</option>
              </select>
            </label>
          {/if}

          {#if state.gravityMode === "focalPoint"}
            <div class="focal-picker-field">
              <span>Focal point</span>
              <button
                class="focal-picker"
                type="button"
                aria-label={`Set focal point, currently ${state.gravityFocalX}, ${state.gravityFocalY}`}
                onclick={updateFocalPoint}
                onpointerdown={startFocalPointDrag}
                onpointermove={dragFocalPoint}
              >
                <span class="focal-image-surface" bind:this={focalPickerSurface}>
                  <img src={`/${state.source}`} alt="" draggable="false" />
                  <span
                    class="focal-marker"
                    style={`left: ${state.gravityFocalX * 100}%; top: ${state.gravityFocalY * 100}%;`}
                  ></span>
                </span>
              </button>
            </div>

            <RangeNumber
              label="Focal X"
              bind:value={state.gravityFocalX}
              min={0}
              max={1}
              step={0.01}
            />
            <RangeNumber
              label="Focal Y"
              bind:value={state.gravityFocalY}
              min={0}
              max={1}
              step={0.01}
            />
          {/if}

          {#if state.gravityMode === "offset"}
            <RangeNumber
              label="Offset X"
              bind:value={state.gravityOffsetX}
              min={-200}
              max={200}
              step={0.01}
            />
            <RangeNumber
              label="Offset Y"
              bind:value={state.gravityOffsetY}
              min={-200}
              max={200}
              step={0.01}
            />
          {/if}
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Format</h2>
            <p>{state.formatEnabled ? `f:${state.format}` : "Off"}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable format"
            bind:checked={state.formatEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.formatEnabled}
          <label class="field">
            <span>Format</span>
            <select bind:value={state.format}>
              <option value="webp">webp</option>
              <option value="avif">avif</option>
              <option value="jpeg">jpeg</option>
              <option value="png">png</option>
            </select>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <div>
            <h2>Quality</h2>
            <p>{state.qualityEnabled ? `q:${state.quality}` : "Off"}</p>
          </div>
          <Switch.Root
            class="switch-root"
            aria-label="Enable quality"
            bind:checked={state.qualityEnabled}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
        </div>

        {#if state.qualityEnabled}
          <RangeNumber label="Quality" bind:value={state.quality} min={0} max={100} step={1} />
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <h2>Request</h2>
        </div>

        <label class="field">
          <span>Source image</span>
          <select bind:value={state.source}>
            <option value="images/dog.jpg">dog.jpg</option>
            <option value="images/cat-300.jpg">cat-300.jpg</option>
          </select>
        </label>

        <label class="field">
          <span>Signature</span>
          <select bind:value={state.signature}>
            <option value="_">unsigned</option>
            <option value="unsafe">unsafe</option>
          </select>
        </label>
      </section>
    </div>

    <div class="drawer-actions">
      <button class="copy-button" type="button" onclick={copyUrl}>{copyLabel}</button>
      <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
    </div>
  </aside>

  <section class="preview-workspace" aria-label="Processed image preview">
    <header class="preview-command-bar">
      <button
        class="icon-button menu-button"
        type="button"
        aria-label="Open tools"
        onclick={() => (drawerOpen = true)}
      >
        ☰
      </button>
      <code class="parameter-preview">{previewParameters}</code>
      <div class="desktop-actions">
        <button class="copy-button copy-button-secondary" type="button" onclick={copyUrl}>{copyLabel}</button>
        <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
      </div>
    </header>

    <div class="preview-canvas">
      <div class="image-frame">
        <figure>
          <img src={path} alt="Processed sample source" onload={updateProcessedMetadata} />
          <figcaption>
            <span>{sizeLabel}</span>
            <span>{outputLabel}</span>
          </figcaption>
        </figure>
      </div>
    </div>
  </section>
</main>

<style>
  .fiddle-shell {
    width: 100%;
    height: 100dvh;
    display: flex;
    overflow: hidden;
    background: var(--surface-app);
  }

  .tools-sidebar {
    width: 332px;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
    background: var(--surface-sidebar);
    border-inline-end: 1px solid var(--border-subtle);
    color: var(--text-primary);
  }

  .drawer-topbar {
    display: none;
  }

  .tool-stack {
    min-height: 0;
    height: 100%;
    padding: 18px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: var(--border-strong) transparent;
  }

  .tool-stack::-webkit-scrollbar {
    width: 10px;
  }

  .tool-stack::-webkit-scrollbar-thumb {
    border: 3px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--border-strong);
  }

  .tool-section {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 14px;
    border-bottom: 1px solid var(--border-subtle);
  }

  .tool-heading {
    min-height: 20px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;

    :where(h2, p) {
      margin: 0;
    }

    h2 {
      font-size: 16px;
      line-height: 20px;
      font-weight: 650;
      color: var(--text-heading);
    }

    p {
      margin-block-start: 2px;
      color: var(--text-muted);
      font-size: 12px;
      line-height: 16px;
    }
  }

  .preview-workspace {
    min-width: 0;
    height: 100dvh;
    flex: 1;
    display: flex;
    flex-direction: column;
    background: var(--surface-app);
  }

  .preview-command-bar {
    height: 64px;
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
    padding-block: 12px;
    padding-inline: 18px;
    border-block-end: 1px solid var(--border-subtle);
    background: var(--surface-bar);
  }

  .parameter-preview {
    min-width: 0;
    flex: 1;
    overflow: hidden;
    color: var(--text-muted);
    font-size: 13px;
    line-height: 18px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .desktop-actions,
  .drawer-actions {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .drawer-actions {
    display: none;
  }

  .copy-button,
  .open-link,
  .icon-button {
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    text-decoration: none;
  }

  .copy-button,
  .open-link {
    height: 40px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0 16px;
    font-size: 14px;
    line-height: 18px;
    font-weight: 700;
  }

  .copy-button {
    min-width: 104px;
    background: var(--button-secondary-bg);
    color: var(--button-secondary-text);
  }

  .copy-button-secondary {
    background: var(--button-secondary-bg);
  }

  .open-link {
    min-width: 76px;
    background: var(--button-primary-bg);
    color: var(--button-primary-text);
  }

  .icon-button {
    width: 36px;
    height: 36px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-strong);
    background: var(--surface-button-quiet);
    color: var(--text-primary);
    font-size: 18px;
    line-height: 1;
  }

  .menu-button {
    display: none;
  }

  .preview-canvas {
    min-height: 0;
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    padding: 28px;
    background:
      repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-canvas) 0 50%)
      50% / 20px 20px;
  }

  .image-frame {
    max-width: calc(100% - 48px);
    max-height: calc(100% - 48px);
    display: flex;
    align-items: center;
    justify-content: center;

    figure {
      position: relative;
      display: inline-flex;
      margin: 0;
      box-shadow: var(--image-shadow);
    }

    img {
      display: block;
      width: auto;
      height: auto;
      max-width: 100%;
      max-height: calc(100dvh - 160px);
    }

    figcaption {
      position: absolute;
      inset-inline: 14px;
      inset-block-end: 14px;
      display: flex;
      justify-content: space-between;
      gap: 12px;
      color: var(--image-overlay-text);
      font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 16px;
      pointer-events: none;
    }
  }

  .field,
  .switch-field,
  .focal-picker-field {
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .tool-subgroup {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-block-start: 2px;
  }

  .subgroup-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;

    code {
      min-width: 0;
      overflow: hidden;
      color: var(--text-muted);
      font-size: 12px;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .focal-picker-field {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .focal-picker {
    width: 100%;
    height: 148px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background:
      repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-control) 0 50%)
      50% / 16px 16px;
    cursor: crosshair;
    padding: 8px;
    touch-action: none;
  }

  .focal-image-surface {
    position: relative;
    display: inline-flex;
    max-width: 100%;
    max-height: 100%;
    box-shadow: var(--image-shadow);
  }

  .focal-image-surface img {
    display: block;
    width: auto;
    height: auto;
    max-width: 100%;
    max-height: 130px;
    pointer-events: none;
    user-select: none;
  }

  .focal-marker {
    position: absolute;
    width: 18px;
    height: 18px;
    border: 2px solid var(--accent);
    border-radius: 999px;
    box-shadow: 0 0 0 1px var(--surface-sidebar), 0 2px 10px rgb(0 0 0 / 0.38);
    pointer-events: none;
    transform: translate(-50%, -50%);
  }

  .focal-marker::before,
  .focal-marker::after {
    position: absolute;
    inset: 50% auto auto 50%;
    display: block;
    background: var(--accent);
    content: "";
    transform: translate(-50%, -50%);
  }

  .focal-marker::before {
    width: 24px;
    height: 2px;
  }

  .focal-marker::after {
    width: 2px;
    height: 24px;
  }

  .field > span {
    display: flex;
    justify-content: space-between;
    gap: 12px;
  }

  select {
    min-width: 0;
    width: 100%;
    height: 38px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    padding-inline: 12px 34px;
    font-size: 14px;
    line-height: 18px;
    appearance: none;
    background-image:
      linear-gradient(45deg, transparent 50%, var(--text-muted) 50%),
      linear-gradient(135deg, var(--text-muted) 50%, transparent 50%);
    background-position:
      calc(100% - 17px) 16px,
      calc(100% - 12px) 16px;
    background-size: 5px 5px;
    background-repeat: no-repeat;
  }

  .color-input {
    width: 100%;
    height: 38px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    padding: 4px;
    cursor: pointer;
  }

  .switch-field {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .fiddle-shell :global(.switch-root) {
    width: 42px;
    height: 24px;
    display: flex;
    flex-shrink: 0;
    align-items: center;
    justify-content: flex-start;
    border: 0;
    border-radius: 999px;
    background: var(--surface-control-track);
    padding: 2px;
    cursor: pointer;
  }

  .fiddle-shell :global(.switch-root[data-state="checked"]) {
    justify-content: flex-end;
    background: var(--accent);
  }

  .fiddle-shell :global(.switch-thumb) {
    display: block;
    width: 20px;
    height: 20px;
    border-radius: 999px;
    background: var(--text-muted);
  }

  .fiddle-shell :global(.switch-root[data-state="checked"] .switch-thumb) {
    background: var(--surface-sidebar);
  }

  .fiddle-shell :global(.switch-root:focus-visible),
  :where(.copy-button, .open-link, .icon-button, select, .focal-picker):focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .mobile-scrim {
    display: none;
  }

  @media (max-width: 720px) {
    .tools-sidebar {
      position: fixed;
      z-index: 3;
      inset-block: 0;
      inset-inline-start: 0;
      width: min(326px, calc(100vw - 48px));
      transform: translateX(-100%);
      transition: transform 180ms ease;
      box-shadow: var(--drawer-shadow);
    }

    .tools-sidebar.is-open {
      transform: translateX(0);
    }

    .drawer-topbar {
      height: 52px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-shrink: 0;
      padding-block: 8px;
      padding-inline: 14px;
      border-block-end: 1px solid var(--border-subtle);
      background: var(--surface-sidebar);
    }

    .drawer-topbar strong {
      font-size: 14px;
      line-height: 18px;
    }

    .tool-stack {
      height: auto;
      flex: 1;
      padding: 0 18px;
    }

    .tool-section {
      padding: 14px;
    }

    .drawer-actions {
      height: 61px;
      display: flex;
      flex-shrink: 0;
      padding-block: 12px;
      padding-inline: 14px;
      border-block-start: 1px solid var(--border-subtle);
      background: var(--surface-sidebar);
    }

    .drawer-actions .copy-button {
      flex: 1;
    }

    .mobile-scrim {
      position: fixed;
      z-index: 2;
      inset: 0;
      display: block;
      border: 0;
      background: var(--scrim);
      opacity: 0;
      pointer-events: none;
      transition: opacity 180ms ease;
    }

    .mobile-scrim.is-open {
      opacity: 1;
      pointer-events: auto;
    }

    .preview-workspace {
      width: 100%;
    }

    .preview-command-bar {
      height: 58px;
      gap: 10px;
      padding-block: 10px;
      padding-inline: 12px;
    }

    .menu-button {
      display: inline-flex;
      width: 40px;
      height: 38px;
    }

    .desktop-actions {
      display: none;
    }

    .parameter-preview {
      font-size: 11px;
      line-height: 14px;
    }

    .preview-canvas {
      padding: 18px;
    }

    .image-frame {
      max-width: 100%;
      max-height: 100%;
    }

    .image-frame img {
      max-height: calc(100dvh - 140px);
    }

    .image-frame figcaption {
      inset-inline: 10px;
      inset-block-end: 10px;
      font-size: 11px;
      line-height: 14px;
    }
  }
</style>
