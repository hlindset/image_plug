<script lang="ts">
  import { Switch } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import {
    buildProcessingPath,
    defaultDemoState,
    resolvedOutputLabel,
    type DemoState
  } from "./processing-path";

  let copyLabel = "Copy URL";
  let drawerOpen = false;
  let state: DemoState = { ...defaultDemoState };

  $: path = buildProcessingPath(state);
  $: previewParameters = path.replace(/^\/(?:_|unsafe)\//, "");
  $: outputLabel = resolvedOutputLabel(state);

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
            <h2>Resize</h2>
            <p>{state.resizeEnabled ? `rs:${state.resizeMode}:${state.width}:${state.height}` : "Off"}</p>
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

          <div class="field-grid">
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

            <label class="field">
              <span>Gravity</span>
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
          </div>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={state.enlarge}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Allow enlargement</span>
          </label>
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
        {/if}
      </section>

      <section class="tool-section">
        <div class="tool-heading">
          <h2>Output</h2>
        </div>

        <label class="field">
          <span>Format</span>
          <select bind:value={state.format}>
            <option value="auto">auto</option>
            <option value="webp">webp</option>
            <option value="avif">avif</option>
            <option value="jpeg">jpeg</option>
            <option value="png">png</option>
          </select>
        </label>

        <RangeNumber label="Quality" bind:value={state.quality} min={0} max={100} step={1} />
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
          <img src={path} alt="Processed sample source" />
          <figcaption>
            <span>{state.width} × {state.height}</span>
            <span>{outputLabel}</span>
          </figcaption>
        </figure>
      </div>
    </div>
  </section>
</main>
