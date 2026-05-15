<script lang="ts">
  import { Switch, Tabs } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import {
    buildProcessingPath,
    defaultDemoState,
    optionSegments,
    type DemoState
  } from "./processing-path";

  type Panel = "resize" | "crop" | "output" | "request";

  let activePanel: string = "resize";
  let copyLabel = "Copy URL";
  let state: DemoState = { ...defaultDemoState };

  $: path = buildProcessingPath(state);
  $: fragment = optionSegments(state).join("/");

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

  const panels: { value: Panel; label: string }[] = [
    { value: "resize", label: "Resize" },
    { value: "crop", label: "Crop" },
    { value: "output", label: "Output" },
    { value: "request", label: "Request" }
  ];
</script>

<main class="fiddle-shell">
  <header class="top-bar">
    <div class="brand-mark" aria-hidden="true">IP</div>
    <div>
      <h1>ImagePlug Fiddle</h1>
      <p>SimpleServer · Svelte · TypeScript · processing path syntax</p>
    </div>
  </header>

  <Tabs.Root class="workspace" aria-label="ImagePlug processing fiddle" bind:value={activePanel} orientation="vertical">
    <Tabs.List class="tool-rail" aria-label="Control groups">
      {#each panels as panel}
        <Tabs.Trigger class="tool-button" value={panel.value}>{panel.label}</Tabs.Trigger>
      {/each}
    </Tabs.List>

    <section class="preview-stage" aria-label="Processed image preview">
      <div class="preview-head">
        <div class="live-label"><span aria-hidden="true"></span> Live processed preview</div>
        <code>{fragment}</code>
      </div>

      <div class="image-viewport">
        <div class="image-frame">
          <img src={path} alt="Processed sample source" />
          <div class="target-frame" aria-hidden="true"></div>
        </div>
      </div>
    </section>

    <aside class="inspector" aria-label="Processing controls">
      <Tabs.Content class="panel" value="resize" data-panel="resize">
        <div class="panel-head">
          <div>
            <h2>Resize</h2>
            <p>Maps to <code>rs</code>, <code>w</code>, <code>h</code>, and <code>g</code>.</p>
          </div>
          <button class="copy-button" type="button" onclick={copyUrl}>{copyLabel}</button>
        </div>

        <RangeNumber label="Width" bind:value={state.width} min={0} max={1600} step={1} />
        <RangeNumber label="Height" bind:value={state.height} min={0} max={1000} step={1} />

        <div class="field-grid">
          <label class="field">
            <span>Resizing type</span>
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
      </Tabs.Content>

      <Tabs.Content class="panel" value="crop" data-panel="crop">
        <div class="panel-head">
          <div>
            <h2>Crop</h2>
            <p>Add an explicit <code>c</code> option before resize planning.</p>
          </div>
        </div>

        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={state.cropEnabled}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Enable crop</span>
        </label>

        <RangeNumber label="Crop width" bind:value={state.cropWidth} min={80} max={1200} step={1} />
        <RangeNumber label="Crop height" bind:value={state.cropHeight} min={80} max={900} step={1} />
      </Tabs.Content>

      <Tabs.Content class="panel" value="output" data-panel="output">
        <div class="panel-head">
          <div>
            <h2>Output</h2>
            <p>Explicit formats bypass <code>Accept</code> negotiation.</p>
          </div>
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
      </Tabs.Content>

      <Tabs.Content class="panel" value="request" data-panel="request">
        <div class="panel-head">
          <div>
            <h2>Request</h2>
            <p>Choose a local source served by SimpleServer.</p>
          </div>
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
            <option value="_">_</option>
            <option value="unsafe">unsafe</option>
          </select>
        </label>
      </Tabs.Content>
    </aside>
  </Tabs.Root>

  <section class="url-tray" aria-label="Generated processing URL">
    <div>
      <span>Generated URL</span>
      <strong>processing path</strong>
    </div>
    <code>{path}</code>
    <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
  </section>
</main>
