<script lang="ts">
  import { onMount } from "svelte";
  import { Collapsible, RadioGroup, Select, Switch, Tabs } from "bits-ui";
  import CropDimensionControl from "./CropDimensionControl.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import ResizeDimensionControl from "./ResizeDimensionControl.svelte";
  import ToolToggleHeader from "./ToolToggleHeader.svelte";
  import {
    demoObjClasses,
    demoPathForState,
    expandedToolboxesForState,
    parseDemoPath,
    resetDemoSettings,
  } from "./demo-url-state";
  import {
    buildProcessingPath,
    controlLimits,
    cropOptionSegment,
    cropPixelLimit,
    debounce,
    defaultDemoState,
    focalPointFromBounds,
    gravitySegment,
    processedSizeLabel,
    processingPathFromSignedPath,
    resizeOptionSegment,
    resetCropPixelsToSource,
    sampleImages,
    signProcessingPath,
    signedPathForState,
    trimOptionSegment,
    resolvedOutputLabel,
    type DemoState,
    type ProcessedImageMetadata,
    type SourceImage,
  } from "./processing-path";
  import {
    applyThemeMode,
    persistThemeMode,
    readStoredThemeMode,
    storedThemeMode,
    type ThemeMode,
  } from "./theme";

  // Demo object classes shown in the picker (subset of COCO-80 + "all" pseudo-class).
  // "all" is offered only in weighted sub-mode to set the baseline weight.
  const demoObjClassesForPicker = demoObjClasses as readonly string[];

  let copyLabel = $state("Copy URL");
  let drawerOpen = $state(false);
  let mobileTools = $state(false);
  let orientationOpen = $state(true);
  let scaleOptionsOpen = $state(true);
  let requestOpen = $state(true);
  let effectsOpen = $state(true);
  let themeMode: ThemeMode = $state(readStoredThemeMode());
  const initialState = initialDemoState();
  let demoState: DemoState = $state(initialState);
  let path = $state(buildProcessingPath(initialState));
  let previewImageUrl: string | null = $state(null);
  let previewLoading = $state(true);
  let previewError: string | null = $state(null);
  let processedMetadata: ProcessedImageMetadata | null = $state(null);
  let signingError: string | null = $state(null);
  // Element references bound via bind:this.
  let focalPickerSurface: HTMLSpanElement | null = $state(null);
  let toolsSidebar: HTMLElement | null = $state(null);
  let menuButton: HTMLButtonElement | null = $state(null);
  let drawerCloseButton: HTMLButtonElement | null = $state(null);
  // Internal, non-reactive bookkeeping: request-id guards, timers and the
  // abort/object-url handles. Nothing reactive reads these, so they stay plain locals.
  let previewPath = "";
  let metadataRequestId = 0;
  let pathRequestId = 0;
  let copyLabelResetTimeout: number | null = null;
  let activePreviewObjectUrl: string | null = null;
  let previewAbortController: AbortController | null = null;
  const updatePreviewPath = debounce((nextPath: string) => {
    if (nextPath !== previewPath) {
      processedMetadata = null;
      previewError = null;
      metadataRequestId += 1;
      previewLoading = true;
    }

    void loadPreview(nextPath);
  }, 150);
  const updateDemoLocation = debounce((nextPath: string) => {
    if (typeof window === "undefined" || window.location.pathname === nextPath) {
      return;
    }

    window.history.replaceState(null, "", nextPath);
  }, 150);
  const previewAcceptHeader = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";

  onMount(() => {
    const mediaQuery = window.matchMedia("(max-width: 720px)");
    const syncMobileTools = () => {
      mobileTools = mediaQuery.matches;
    };

    syncMobileTools();
    mediaQuery.addEventListener("change", syncMobileTools);
    window.addEventListener("popstate", restoreStateFromLocation);
    restoreStateFromLocation();

    return () => {
      mediaQuery.removeEventListener("change", syncMobileTools);
      window.removeEventListener("popstate", restoreStateFromLocation);
      previewAbortController?.abort();
      revokePreviewObjectUrl();
    };
  });

  $effect(() => {
    updateProcessingPath(demoState);
  });
  $effect(() => {
    updatePreviewPath(path);
  });
  $effect(() => {
    updateDemoLocation(demoPathForState(demoState));
  });
  $effect(() => {
    ensureActiveToolboxesOpen(demoState);
  });
  $effect(() => {
    applyThemeMode(themeMode);
  });
  $effect(() => {
    persistThemeMode(themeMode);
  });

  const previewParameters = $derived(path.replace(/^\/[^/]+\/[^/]+\//, ""));
  const outputLabel = $derived(resolvedOutputLabel(demoState, processedMetadata));
  const sizeLabel = $derived(previewError ?? processedSizeLabel(processedMetadata));
  const requestSummary = $derived(
    `${demoState.source.replace(/^images\//, "")} / ${requestSignatureLabel(demoState, signingError)}`,
  );
  const orientationSummary = $derived(
    [
      demoState.autoRotateEnabled ? "ar:1" : null,
      flipSegment(demoState.flip),
      demoState.rotate === 0 ? null : `rot:${demoState.rotate}`,
    ]
      .filter(Boolean)
      .join("/") || "Off",
  );
  const trimSummary = $derived(
    demoState.trimEnabled ? (trimOptionSegment(demoState) ?? "Off") : "Off",
  );
  const resizeSummary = $derived(
    demoState.resizeEnabled ? (resizeOptionSegment(demoState) ?? "Off") : "Off",
  );
  const aspectCanvasSummary = $derived(
    demoState.aspectCanvasEnabled
      ? demoState.aspectCanvasGravity === "ce"
        ? "exar:1"
        : `exar:1:${demoState.aspectCanvasGravity}`
      : "Off",
  );
  const paddingSummary = $derived(
    demoState.paddingEnabled
      ? `pd:${demoState.paddingTop}:${demoState.paddingRight}:${demoState.paddingBottom}:${demoState.paddingLeft}`
      : "Off",
  );
  const backgroundSummary = $derived(
    demoState.backgroundEnabled
      ? `bg:${demoState.backgroundColor.replace(/^#/, "")}${backgroundOpacitySummary(demoState.backgroundAlpha)}`
      : "Off",
  );
  const effectsSummary = $derived(effectSegments(demoState).join("/") || "Off");
  const metadataSummary = $derived(metadataSegments(demoState).join("/") || "On");
  const cropSummary = $derived(
    demoState.cropEnabled ? (cropOptionSegment(demoState) ?? "Off") : "Off",
  );
  const cropAspectRatioSummary = $derived(
    demoState.cropAspectRatioEnabled
      ? demoState.cropAspectRatioEnlarge
        ? `car:${demoState.cropAspectRatio}:1`
        : `car:${demoState.cropAspectRatio}`
      : "Off",
  );
  const resizeExtras = $derived(
    [
      demoState.zoomEnabled ? `z:${demoState.zoom}` : null,
      demoState.dprEnabled ? `dpr:${demoState.dpr}` : null,
      demoState.minWidthEnabled ? `mw:${demoState.minWidth}` : null,
      demoState.minHeightEnabled ? `mh:${demoState.minHeight}` : null,
    ]
      .filter(Boolean)
      .join("/"),
  );
  const cropWidthLimit = $derived(cropPixelLimit(demoState.source, "width"));
  const cropHeightLimit = $derived(cropPixelLimit(demoState.source, "height"));

  function initialDemoState(): DemoState {
    if (typeof window === "undefined") {
      return { ...defaultDemoState };
    }

    return parseDemoPath(window.location.pathname);
  }

  function restoreStateFromLocation(): void {
    demoState = parseDemoPath(window.location.pathname);
    ensureActiveToolboxesOpen(demoState);
  }

  function ensureActiveToolboxesOpen(currentState: DemoState): void {
    const expandedToolboxes = expandedToolboxesForState(currentState);

    if (expandedToolboxes.orientationOpen) {
      orientationOpen = true;
    }

    if (expandedToolboxes.scaleOptionsOpen) {
      scaleOptionsOpen = true;
    }

    if (expandedToolboxes.effectsOpen) {
      effectsOpen = true;
    }
  }

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

  function backgroundOpacitySummary(alpha: number): string {
    if (alpha >= 1) {
      return "";
    }

    return `/bga:${alpha}`;
  }

  function metadataSegments(currentState: DemoState): string[] {
    const segs: string[] = [];

    if (!currentState.stripMetadata) {
      segs.push("sm:0");
    } else if (!currentState.keepCopyright) {
      segs.push("kcr:0");
    }

    if (!currentState.stripColorProfile) {
      segs.push("scp:0");
    }

    if (currentState.colorProfile !== "none") {
      segs.push(`cp:${currentState.colorProfile}`);
    }

    if (currentState.preserveHdr) {
      segs.push("ph:1");
    }

    return segs;
  }

  function effectSegments(currentState: DemoState): string[] {
    return [
      currentState.blurEnabled ? `bl:${currentState.blur}` : null,
      currentState.sharpenEnabled ? `sh:${currentState.sharpen}` : null,
      currentState.pixelateEnabled ? `pix:${currentState.pixelate}` : null,
      currentState.monochromeEnabled
        ? `mc:${currentState.monochromeIntensity}:${currentState.monochromeColor.replace(/^#/, "")}`
        : null,
      currentState.duotoneEnabled
        ? `dt:${currentState.duotoneIntensity}:${currentState.duotoneShadow.replace(
            /^#/,
            "",
          )}:${currentState.duotoneHighlight.replace(/^#/, "")}`
        : null,
      currentState.brightnessEnabled ? `br:${currentState.brightness}` : null,
      currentState.contrastEnabled ? `co:${currentState.contrast}` : null,
      currentState.saturationEnabled ? `sa:${currentState.saturation}` : null,
    ].filter((segment): segment is string => segment !== null);
  }

  function requestSignatureLabel(
    currentState: DemoState,
    currentSigningError: string | null,
  ): string {
    if (currentState.signatureMode === "signed") {
      return currentSigningError === null ? "signed" : "signed: invalid key";
    }

    return currentState.signatureMode;
  }

  function updateProcessingPath(currentState: DemoState): void {
    const requestId = ++pathRequestId;
    const signedPath = signedPathForState(currentState);

    if (currentState.signatureMode !== "signed") {
      signingError = null;
      path = buildProcessingPath(currentState);
      return;
    }

    signProcessingPath(signedPath, currentState.signatureKey, currentState.signatureSalt)
      .then((signature) => {
        if (requestId === pathRequestId) {
          signingError = null;
          path = processingPathFromSignedPath(signature, signedPath);
        }
      })
      .catch((error: unknown) => {
        if (requestId === pathRequestId) {
          signingError = error instanceof Error ? error.message : "Unable to sign request";
          path = processingPathFromSignedPath("invalid-signature", signedPath);
        }
      });
  }

  async function loadPreview(nextPath: string): Promise<void> {
    const requestId = ++metadataRequestId;
    previewAbortController?.abort();
    const abortController = new AbortController();
    let objectUrl: string | null = null;

    previewAbortController = abortController;
    previewPath = nextPath;
    previewLoading = true;
    previewError = null;
    processedMetadata = null;

    try {
      const response = await fetch(nextPath, {
        cache: "no-cache",
        headers: { accept: previewAcceptHeader },
        signal: abortController.signal,
      });
      const contentType = response.headers.get("content-type");

      if (!response.ok) {
        const message = await previewErrorFromResponse(response);

        if (requestId === metadataRequestId) {
          previewLoading = false;
          previewError = message;
          processedMetadata = null;
        }

        return;
      }

      const blob = await response.blob();
      objectUrl = URL.createObjectURL(blob);
      const dimensions = await imageDimensions(objectUrl);

      if (requestId === metadataRequestId) {
        revokePreviewObjectUrl();
        activePreviewObjectUrl = objectUrl;
        previewImageUrl = objectUrl;
        previewLoading = false;
        processedMetadata = {
          ...dimensions,
          bytes: blob.size,
          contentType: contentType ?? blob.type ?? null,
        };
        objectUrl = null;
      } else {
        URL.revokeObjectURL(objectUrl);
        objectUrl = null;
      }
    } catch (error) {
      if (objectUrl !== null) {
        URL.revokeObjectURL(objectUrl);
      }

      if (error instanceof DOMException && error.name === "AbortError") {
        return;
      }

      if (requestId === metadataRequestId) {
        previewLoading = false;
        previewError = previewErrorMessage(error);
        processedMetadata = null;
      }
    } finally {
      if (previewAbortController === abortController) {
        previewAbortController = null;
      }
    }
  }

  async function previewErrorFromResponse(response: Response): Promise<string> {
    const status = `${response.status} ${response.statusText || "Preview request failed"}`;

    try {
      const body = (await response.text()).trim();

      if (body !== "") {
        return `${status}: ${body.slice(0, 180)}`;
      }
    } catch {
      return status;
    }

    return status;
  }

  function previewErrorMessage(error: unknown): string {
    return error instanceof Error ? error.message : "Preview request failed";
  }

  function imageDimensions(objectUrl: string): Promise<{ width: number; height: number }> {
    return new Promise((resolve, reject) => {
      const image = new Image();

      image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight });
      image.onerror = () => reject(new Error("Preview image could not be decoded"));
      image.src = objectUrl;
    });
  }

  function revokePreviewObjectUrl(): void {
    if (activePreviewObjectUrl !== null) {
      URL.revokeObjectURL(activePreviewObjectUrl);
      activePreviewObjectUrl = null;
    }
  }

  async function copyGeneratedUrl(): Promise<void> {
    const absoluteUrl = new URL(path, window.location.origin).toString();

    await navigator.clipboard.writeText(absoluteUrl);
    showCopyLabel("Copied");
  }

  function copyUrl(): void {
    copyGeneratedUrl().catch(() => {
      showCopyLabel("Copy failed");
    });
  }

  function showCopyLabel(label: string): void {
    if (copyLabelResetTimeout !== null) {
      window.clearTimeout(copyLabelResetTimeout);
    }

    copyLabel = label;
    copyLabelResetTimeout = window.setTimeout(() => {
      copyLabel = "Copy URL";
      copyLabelResetTimeout = null;
    }, 1200);
  }

  function updateFocalPoint(event: MouseEvent | PointerEvent): void {
    if (event instanceof MouseEvent && event.type === "click" && event.detail === 0) {
      return;
    }

    if (focalPickerSurface === null) {
      return;
    }

    const focalPoint = focalPointFromBounds(
      event.clientX,
      event.clientY,
      focalPickerSurface.getBoundingClientRect(),
    );

    demoState.gravityFocalX = focalPoint.x;
    demoState.gravityFocalY = focalPoint.y;
  }

  function startFocalPointDrag(event: PointerEvent): void {
    const target = event.currentTarget;

    if (target instanceof HTMLElement) {
      target.setPointerCapture(event.pointerId);
    }

    updateFocalPoint(event);
  }

  function moveFocalPoint(event: KeyboardEvent): void {
    const step = event.shiftKey ? 0.1 : 0.01;

    if (event.key === "ArrowLeft") {
      event.preventDefault();
      demoState.gravityFocalX = Math.max(0, roundedFocalPoint(demoState.gravityFocalX - step));
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      demoState.gravityFocalX = Math.min(1, roundedFocalPoint(demoState.gravityFocalX + step));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      demoState.gravityFocalY = Math.max(0, roundedFocalPoint(demoState.gravityFocalY - step));
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      demoState.gravityFocalY = Math.min(1, roundedFocalPoint(demoState.gravityFocalY + step));
    } else if (event.key === "Home") {
      event.preventDefault();
      demoState.gravityFocalX = 0.5;
      demoState.gravityFocalY = 0.5;
    }
  }

  function roundedFocalPoint(value: number): number {
    return Math.round(value * 100) / 100;
  }

  function dragFocalPoint(event: PointerEvent): void {
    if (event.buttons !== 1) {
      return;
    }

    updateFocalPoint(event);
  }

  function updateCropEnabled(enabled: boolean): void {
    demoState.cropEnabled = enabled;

    if (enabled) {
      demoState = resetCropPixelsToSource(demoState);
    }
  }

  function updateSource(event: Event): void {
    const select = event.currentTarget;

    if (!(select instanceof HTMLSelectElement)) {
      return;
    }

    demoState = resetCropPixelsToSource({
      ...demoState,
      source: select.value as SourceImage,
    });
  }

  function setThemeMode(nextMode: string): void {
    themeMode = storedThemeMode(nextMode);
  }

  function updateStripMetadata(checked: boolean): void {
    demoState.stripMetadata = checked;

    if (!checked) {
      demoState.keepCopyright = false;
    }
  }

  function syncObjClasses(nextClasses: string[]): void {
    // Add default weight for newly selected classes; remove weight for deselected ones.
    const prev = new Set(demoState.objSelectedClasses);
    const next = new Set(nextClasses);
    let weights = { ...demoState.objWeights };

    for (const cls of next) {
      if (!prev.has(cls)) {
        weights = { ...weights, [cls]: weights[cls] ?? 1 };
      }
    }

    for (const cls of prev) {
      if (!next.has(cls)) {
        const { [cls]: _removed, ...rest } = weights;

        weights = rest;
      }
    }

    demoState.objSelectedClasses = nextClasses;
    demoState.objWeights = weights;
  }

  function objClassTriggerLabel(selected: string[]): string {
    if (selected.length === 0) {
      return "All objects";
    }

    if (selected.length === 1) {
      return selected[0]!;
    }

    return `${selected.length} classes`;
  }

  function resetSettings(): void {
    demoState = resetDemoSettings(demoState);
  }

  function closeTools(): void {
    drawerOpen = false;

    if (mobileTools) {
      window.requestAnimationFrame(() => menuButton?.focus());
    }
  }

  function openTools(): void {
    drawerOpen = true;

    if (mobileTools) {
      window.requestAnimationFrame(() => drawerCloseButton?.focus());
    }
  }

  function handleToolsKeydown(event: KeyboardEvent): void {
    if (!mobileTools || !drawerOpen) {
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      closeTools();
      return;
    }

    if (event.key === "Tab") {
      trapDrawerFocus(event);
    }
  }

  function trapDrawerFocus(event: KeyboardEvent): void {
    if (toolsSidebar === null) {
      return;
    }

    const focusableElements = Array.from(
      toolsSidebar.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ).filter((element) => element.getClientRects().length > 0 && element.tabIndex >= 0);
    const firstElement = focusableElements[0];
    const lastElement = focusableElements.at(-1);

    if (firstElement === undefined || lastElement === undefined) {
      return;
    }

    if (event.shiftKey && document.activeElement === firstElement) {
      event.preventDefault();
      lastElement.focus();
    } else if (!event.shiftKey && document.activeElement === lastElement) {
      event.preventDefault();
      firstElement.focus();
    }
  }
</script>

<main class="fiddle-shell">
  <button
    class="mobile-scrim"
    class:is-open={drawerOpen}
    type="button"
    tabindex={drawerOpen ? 0 : -1}
    aria-hidden={drawerOpen ? "false" : "true"}
    aria-label="Close tools"
    onclick={closeTools}
  ></button>

  <aside
    class="tools-sidebar"
    class:is-open={drawerOpen}
    aria-label="Processing controls"
    aria-hidden={mobileTools && !drawerOpen ? "true" : "false"}
    inert={mobileTools && !drawerOpen}
    bind:this={toolsSidebar}
    onkeydown={handleToolsKeydown}
  >
    <div class="drawer-topbar">
      <strong>Tools</strong>
      <button
        class="icon-button"
        type="button"
        aria-label="Close tools"
        bind:this={drawerCloseButton}
        onclick={closeTools}
      >
        ×
      </button>
    </div>

    <div class="tool-stack">
      <section class="tool-section">
        <Collapsible.Root class="collapsible-root" bind:open={requestOpen}>
          <Collapsible.Trigger
            class="accordion-heading"
            aria-label={requestOpen ? "Collapse request" : "Expand request"}
          >
            <div>
              <h2>Request</h2>
              <p>{requestSummary}</p>
            </div>
            <span class="accordion-chevron" aria-hidden="true"></span>
          </Collapsible.Trigger>

          <Collapsible.Content class="collapsible-content">
            <label class="field">
              <span>Source image</span>
              <select value={demoState.source} onchange={updateSource}>
                {#each sampleImages as image}
                  <option value={image.path}>{image.label}</option>
                {/each}
              </select>
            </label>

            <label class="field">
              <span>Signature</span>
              <select bind:value={demoState.signatureMode}>
                <option value="unsigned">unsigned</option>
                <option value="signed">signed</option>
              </select>
            </label>

            {#if demoState.signatureMode === "signed"}
              <div class="signature-secret-grid">
                <label class="field">
                  <span>Key</span>
                  <input
                    class="text-input text-input-mono"
                    bind:value={demoState.signatureKey}
                    spellcheck="false"
                    autocomplete="off"
                  />
                </label>

                <label class="field">
                  <span>Salt</span>
                  <input
                    class="text-input text-input-mono"
                    bind:value={demoState.signatureSalt}
                    spellcheck="false"
                    autocomplete="off"
                  />
                </label>
              </div>

              {#if signingError !== null}
                <p class="field-error">{signingError}</p>
              {/if}
            {/if}
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Resize"
          summary={resizeSummary}
          bind:checked={demoState.resizeEnabled}
        />

        {#if demoState.resizeEnabled}
          <ResizeDimensionControl
            label="Width"
            bind:unit={demoState.resizeWidthUnit}
            bind:pixels={demoState.width}
            maxPixels={controlLimits.resize.width.max}
          />
          <ResizeDimensionControl
            label="Height"
            bind:unit={demoState.resizeHeightUnit}
            bind:pixels={demoState.height}
            maxPixels={controlLimits.resize.height.max}
          />

          <label class="field">
            <span>Type</span>
            <select bind:value={demoState.resizeMode}>
              <option value="fit">fit</option>
              <option value="fill">fill</option>
              <option value="fill-down">fill-down</option>
              <option value="force">force</option>
              <option value="auto">auto</option>
            </select>
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={demoState.enlarge}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Allow enlargement</span>
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={demoState.resizeExtendEnabled}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Extend result</span>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Crop"
          summary={cropSummary}
          checked={demoState.cropEnabled}
          onCheckedChange={updateCropEnabled}
        />

        {#if demoState.cropEnabled}
          <CropDimensionControl
            label="Width"
            bind:unit={demoState.cropWidthUnit}
            bind:pixels={demoState.cropWidth}
            bind:percent={demoState.cropWidthPercent}
            maxPixels={cropWidthLimit.max}
          />
          <CropDimensionControl
            label="Height"
            bind:unit={demoState.cropHeightUnit}
            bind:pixels={demoState.cropHeight}
            bind:percent={demoState.cropHeightPercent}
            maxPixels={cropHeightLimit.max}
          />

          <label class="field">
            <span>Gravity</span>
            <select bind:value={demoState.cropGravity}>
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
              <option value="sm">smart</option>
              <option value="obj:face">object (face)</option>
              <option value="obj">object (all, bare)</option>
              <option value="obj:all">object (all, explicit)</option>
            </select>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Crop aspect ratio"
          summary={cropAspectRatioSummary}
          bind:checked={demoState.cropAspectRatioEnabled}
        />

        {#if demoState.cropAspectRatioEnabled}
          <RangeNumber
            label="Ratio"
            bind:value={demoState.cropAspectRatio}
            min={0}
            max={10}
            step={0.1}
          />
          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={demoState.cropAspectRatioEnlarge}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Enlarge</span>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Gravity"
          summary={demoState.gravityEnabled ? gravitySegment(demoState) : "Off"}
          bind:checked={demoState.gravityEnabled}
        />

        {#if demoState.gravityEnabled}
          <label class="field">
            <span>Mode</span>
            <select bind:value={demoState.gravityMode}>
              <option value="anchor">anchor</option>
              <option value="focalPoint">focal point</option>
              <option value="offset">anchor + offset</option>
              <option value="smart">smart</option>
              <option value="objFace">object (face)</option>
              <option value="object">object (detect)</option>
            </select>
          </label>

          {#if demoState.gravityMode === "anchor" || demoState.gravityMode === "offset"}
            <label class="field">
              <span>Anchor</span>
              <select bind:value={demoState.gravity}>
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

          {#if demoState.gravityMode === "focalPoint"}
            <div class="focal-picker-field">
              <span>Focal point</span>
              <button
                class="focal-picker"
                type="button"
                aria-label={`Set focal point, currently ${demoState.gravityFocalX}, ${demoState.gravityFocalY}`}
                onclick={updateFocalPoint}
                onkeydown={moveFocalPoint}
                onpointerdown={startFocalPointDrag}
                onpointermove={dragFocalPoint}
              >
                <span class="focal-image-surface" bind:this={focalPickerSurface}>
                  <img src={`/${demoState.source}`} alt="" draggable="false" />
                  <span
                    class="focal-marker"
                    style={`left: ${demoState.gravityFocalX * 100}%; top: ${demoState.gravityFocalY * 100}%;`}
                  ></span>
                </span>
              </button>
            </div>

            <RangeNumber
              label="Focal X"
              bind:value={demoState.gravityFocalX}
              min={controlLimits.focalPoint.min}
              max={controlLimits.focalPoint.max}
              step={controlLimits.focalPoint.step}
            />
            <RangeNumber
              label="Focal Y"
              bind:value={demoState.gravityFocalY}
              min={controlLimits.focalPoint.min}
              max={controlLimits.focalPoint.max}
              step={controlLimits.focalPoint.step}
            />
          {/if}

          {#if demoState.gravityMode === "offset"}
            <RangeNumber
              label="Offset X"
              bind:value={demoState.gravityOffsetX}
              min={controlLimits.gravityOffset.min}
              max={controlLimits.gravityOffset.max}
              step={controlLimits.gravityOffset.step}
            />
            <RangeNumber
              label="Offset Y"
              bind:value={demoState.gravityOffsetY}
              min={controlLimits.gravityOffset.min}
              max={controlLimits.gravityOffset.max}
              step={controlLimits.gravityOffset.step}
            />
          {/if}

          {#if demoState.gravityMode === "object"}
            <!-- Object-gravity mode: filter detection to named classes + optional weights.
                 Simple = g:obj:<classes> (filters but no weight bias).
                 Weighted = g:objw:<class>:<weight>... (filters AND weights).
                 Empty selection = bare g:obj (all objects, no filter). -->
            <Tabs.Root
              class="obj-submode-tabs"
              value={demoState.objSubMode}
              onValueChange={(v) => {
                demoState.objSubMode = v as "simple" | "weighted";
              }}
            >
              <Tabs.List class="obj-submode-list">
                <Tabs.Trigger class="obj-submode-trigger" value="simple">Simple</Tabs.Trigger>
                <Tabs.Trigger class="obj-submode-trigger" value="weighted">Weighted</Tabs.Trigger>
              </Tabs.List>
            </Tabs.Root>

            <div class="field">
              <span>
                {demoState.gravityMode === "object" && demoState.objSubMode === "weighted"
                  ? "Classes + weights"
                  : "Classes"}
              </span>
              <!-- Multi-select dropdown: choose individual detection classes.
                   Empty selection = all objects (bare g:obj).
                   In weighted mode "all" is offered as a baseline option. -->
              <Select.Root
                type="multiple"
                value={demoState.objSelectedClasses}
                onValueChange={syncObjClasses}
              >
                <Select.Trigger class="obj-class-trigger">
                  {objClassTriggerLabel(demoState.objSelectedClasses)}
                  <span class="obj-class-trigger-chevron" aria-hidden="true"></span>
                </Select.Trigger>
                <Select.Content class="obj-class-content" sideOffset={4}>
                  <Select.Viewport class="obj-class-viewport">
                    {#if demoState.objSubMode === "weighted"}
                      <Select.Item class="obj-class-item" value="all" label="all">
                        {#snippet children({ selected })}
                          <span class="obj-class-item-check" aria-hidden="true">
                            {#if selected}✓{/if}
                          </span>
                          all
                        {/snippet}
                      </Select.Item>
                    {/if}
                    {#each demoObjClassesForPicker as cls}
                      <Select.Item class="obj-class-item" value={cls} label={cls}>
                        {#snippet children({ selected })}
                          <span class="obj-class-item-check" aria-hidden="true">
                            {#if selected}✓{/if}
                          </span>
                          {cls}
                        {/snippet}
                      </Select.Item>
                    {/each}
                  </Select.Viewport>
                </Select.Content>
              </Select.Root>
              {#if demoState.objSelectedClasses.length === 0}
                <p class="field-hint">No classes selected — detects all objects.</p>
              {/if}
            </div>

            {#if demoState.objSubMode === "weighted" && demoState.objSelectedClasses.length > 0}
              {#each demoState.objSelectedClasses as cls (cls)}
                <RangeNumber
                  label={cls === "all" ? "Baseline weight (all)" : `${cls} weight`}
                  value={demoState.objWeights[cls] ?? 1}
                  min={0.1}
                  max={10}
                  step={0.1}
                  inputStep="any"
                  onValueChange={(w) => {
                    demoState.objWeights = { ...demoState.objWeights, [cls]: w };
                  }}
                />
              {/each}
              <p class="field-hint">
                Weights bias the crop focal point toward a class. Non-uniform weights emit
                <code>g:objw</code>; uniform weights use the compact <code>g:obj</code> form.
              </p>
            {/if}
          {/if}
        {/if}
      </section>

      <section class="tool-section">
        <Collapsible.Root class="collapsible-root" bind:open={scaleOptionsOpen}>
          <Collapsible.Trigger
            class="accordion-heading"
            aria-label={scaleOptionsOpen ? "Collapse scale options" : "Expand scale options"}
          >
            <div>
              <h2>Scale options</h2>
              <p>{resizeExtras || "Off"}</p>
            </div>
            <span class="accordion-chevron" aria-hidden="true"></span>
          </Collapsible.Trigger>

          <Collapsible.Content class="collapsible-content">
            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.zoomEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Zoom</span>
            </label>
            {#if demoState.zoomEnabled}
              <RangeNumber
                label="Zoom"
                bind:value={demoState.zoom}
                min={controlLimits.scale.zoom.min}
                max={controlLimits.scale.zoom.max}
                step={controlLimits.scale.zoom.step}
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.dprEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>DPR</span>
            </label>
            {#if demoState.dprEnabled}
              <RangeNumber
                label="DPR"
                bind:value={demoState.dpr}
                min={controlLimits.scale.dpr.min}
                max={controlLimits.scale.dpr.max}
                step={controlLimits.scale.dpr.step}
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.minWidthEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Minimum width</span>
            </label>
            {#if demoState.minWidthEnabled}
              <RangeNumber
                label="Min width"
                bind:value={demoState.minWidth}
                min={controlLimits.scale.minWidth.min}
                max={controlLimits.scale.minWidth.max}
                step={controlLimits.scale.minWidth.step}
                suffix="px"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.minHeightEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Minimum height</span>
            </label>
            {#if demoState.minHeightEnabled}
              <RangeNumber
                label="Min height"
                bind:value={demoState.minHeight}
                min={controlLimits.scale.minHeight.min}
                max={controlLimits.scale.minHeight.max}
                step={controlLimits.scale.minHeight.step}
                suffix="px"
              />
            {/if}
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      <section class="tool-section">
        <Collapsible.Root class="collapsible-root" bind:open={orientationOpen}>
          <Collapsible.Trigger
            class="accordion-heading"
            aria-label={orientationOpen ? "Collapse orientation" : "Expand orientation"}
          >
            <div>
              <h2>Orientation</h2>
              <p>{orientationSummary}</p>
            </div>
            <span class="accordion-chevron" aria-hidden="true"></span>
          </Collapsible.Trigger>

          <Collapsible.Content class="collapsible-content">
            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.autoRotateEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Auto rotate from EXIF</span>
            </label>

            <label class="field">
              <span>Flip</span>
              <select bind:value={demoState.flip}>
                <option value="none">none</option>
                <option value="horizontal">horizontal</option>
                <option value="vertical">vertical</option>
                <option value="both">both</option>
              </select>
            </label>

            <label class="field">
              <span>Rotate</span>
              <select bind:value={demoState.rotate}>
                <option value={0}>none</option>
                <option value={90}>90°</option>
                <option value={180}>180°</option>
                <option value={270}>270°</option>
              </select>
            </label>
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      <section class="tool-section">
        <ToolToggleHeader title="Trim" summary={trimSummary} bind:checked={demoState.trimEnabled} />

        {#if demoState.trimEnabled}
          <RangeNumber
            label="Threshold"
            bind:value={demoState.trimThreshold}
            min={0}
            max={100}
            step={1}
          />

          <label class="field">
            <span>Background</span>
            <select bind:value={demoState.trimBackgroundMode}>
              <option value="auto">auto (smart detect)</option>
              <option value="color">color</option>
            </select>
          </label>

          {#if demoState.trimBackgroundMode === "color"}
            <label class="field trim-color-field">
              <span>Color</span>
              <input class="color-input" type="color" bind:value={demoState.trimColor} />
            </label>
          {/if}

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={demoState.trimEqualHor}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Equal horizontal</span>
          </label>

          <label class="switch-field">
            <Switch.Root class="switch-root" bind:checked={demoState.trimEqualVer}>
              <Switch.Thumb class="switch-thumb" />
            </Switch.Root>
            <span>Equal vertical</span>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Aspect canvas"
          summary={aspectCanvasSummary}
          bind:checked={demoState.aspectCanvasEnabled}
        />

        {#if demoState.aspectCanvasEnabled}
          <label class="field">
            <span>Gravity</span>
            <select bind:value={demoState.aspectCanvasGravity}>
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
        <ToolToggleHeader
          title="Padding"
          summary={paddingSummary}
          bind:checked={demoState.paddingEnabled}
        />

        {#if demoState.paddingEnabled}
          <RangeNumber
            label="Top"
            bind:value={demoState.paddingTop}
            min={controlLimits.padding.min}
            max={controlLimits.padding.max}
            step={controlLimits.padding.step}
            suffix="px"
          />
          <RangeNumber
            label="Right"
            bind:value={demoState.paddingRight}
            min={controlLimits.padding.min}
            max={controlLimits.padding.max}
            step={controlLimits.padding.step}
            suffix="px"
          />
          <RangeNumber
            label="Bottom"
            bind:value={demoState.paddingBottom}
            min={controlLimits.padding.min}
            max={controlLimits.padding.max}
            step={controlLimits.padding.step}
            suffix="px"
          />
          <RangeNumber
            label="Left"
            bind:value={demoState.paddingLeft}
            min={controlLimits.padding.min}
            max={controlLimits.padding.max}
            step={controlLimits.padding.step}
            suffix="px"
          />
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Background"
          summary={backgroundSummary}
          bind:checked={demoState.backgroundEnabled}
        />

        {#if demoState.backgroundEnabled}
          <div class="background-controls">
            <label class="field background-color-field">
              <span>Color</span>
              <input class="color-input" type="color" bind:value={demoState.backgroundColor} />
            </label>

            <div class="background-opacity-field">
              <RangeNumber
                label="Opacity"
                bind:value={demoState.backgroundAlpha}
                min={controlLimits.alpha.min}
                max={controlLimits.alpha.max}
                step={controlLimits.alpha.step}
                inputStep="any"
              />
            </div>
          </div>
        {/if}
      </section>

      <section class="tool-section">
        <Collapsible.Root class="collapsible-root" bind:open={effectsOpen}>
          <Collapsible.Trigger
            class="accordion-heading"
            aria-label={effectsOpen ? "Collapse effects" : "Expand effects"}
          >
            <div>
              <h2>Effects</h2>
              <p>{effectsSummary}</p>
            </div>
            <span class="accordion-chevron" aria-hidden="true"></span>
          </Collapsible.Trigger>

          <Collapsible.Content class="collapsible-content">
            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.blurEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Blur</span>
            </label>
            {#if demoState.blurEnabled}
              <RangeNumber
                label="Blur sigma"
                bind:value={demoState.blur}
                min={controlLimits.effects.blur.min}
                max={controlLimits.effects.blur.max}
                step={controlLimits.effects.blur.step}
                inputStep="any"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.sharpenEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Sharpen</span>
            </label>
            {#if demoState.sharpenEnabled}
              <RangeNumber
                label="Sharpen sigma"
                bind:value={demoState.sharpen}
                min={controlLimits.effects.sharpen.min}
                max={controlLimits.effects.sharpen.max}
                step={controlLimits.effects.sharpen.step}
                inputStep="any"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.pixelateEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Pixelate</span>
            </label>
            {#if demoState.pixelateEnabled}
              <RangeNumber
                label="Block size"
                bind:value={demoState.pixelate}
                min={controlLimits.effects.pixelate.min}
                max={controlLimits.effects.pixelate.max}
                step={controlLimits.effects.pixelate.step}
                suffix="px"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.monochromeEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Monochrome</span>
            </label>
            {#if demoState.monochromeEnabled}
              <div class="monochrome-control-row">
                <RangeNumber
                  label="Intensity"
                  bind:value={demoState.monochromeIntensity}
                  min={controlLimits.effects.intensity.min}
                  max={controlLimits.effects.intensity.max}
                  step={controlLimits.effects.intensity.step}
                  inputStep="any"
                />
                <label class="field monochrome-color-field">
                  <span>Color</span>
                  <input class="color-input" type="color" bind:value={demoState.monochromeColor} />
                </label>
              </div>
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.duotoneEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Duotone</span>
            </label>
            {#if demoState.duotoneEnabled}
              <div class="duotone-control-row">
                <RangeNumber
                  label="Intensity"
                  bind:value={demoState.duotoneIntensity}
                  min={controlLimits.effects.intensity.min}
                  max={controlLimits.effects.intensity.max}
                  step={controlLimits.effects.intensity.step}
                  inputStep="any"
                />
                <div class="duotone-color-controls">
                  <label class="field">
                    <span>Shadow</span>
                    <input class="color-input" type="color" bind:value={demoState.duotoneShadow} />
                  </label>
                  <label class="field">
                    <span>Highlight</span>
                    <input
                      class="color-input"
                      type="color"
                      bind:value={demoState.duotoneHighlight}
                    />
                  </label>
                </div>
              </div>
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.brightnessEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Brightness</span>
            </label>
            {#if demoState.brightnessEnabled}
              <RangeNumber
                label="Brightness"
                bind:value={demoState.brightness}
                min={controlLimits.effects.brightness.min}
                max={controlLimits.effects.brightness.max}
                step={controlLimits.effects.brightness.step}
                suffix="%"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.contrastEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Contrast</span>
            </label>
            {#if demoState.contrastEnabled}
              <RangeNumber
                label="Contrast"
                bind:value={demoState.contrast}
                min={controlLimits.effects.contrast.min}
                max={controlLimits.effects.contrast.max}
                step={controlLimits.effects.contrast.step}
                suffix="%"
              />
            {/if}

            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={demoState.saturationEnabled}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Saturation</span>
            </label>
            {#if demoState.saturationEnabled}
              <RangeNumber
                label="Saturation"
                bind:value={demoState.saturation}
                min={controlLimits.effects.saturation.min}
                max={controlLimits.effects.saturation.max}
                step={controlLimits.effects.saturation.step}
                suffix="%"
              />
            {/if}
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Format"
          summary={demoState.formatEnabled ? `f:${demoState.format}` : "Off"}
          bind:checked={demoState.formatEnabled}
        />

        {#if demoState.formatEnabled}
          <label class="field">
            <span>Format</span>
            <select bind:value={demoState.format}>
              <option value="webp">webp</option>
              <option value="avif">avif</option>
              <option value="jpeg">jpeg</option>
              <option value="png">png</option>
            </select>
          </label>
        {/if}
      </section>

      <section class="tool-section">
        <ToolToggleHeader
          title="Quality"
          summary={demoState.qualityEnabled ? `q:${demoState.quality}` : "Off"}
          bind:checked={demoState.qualityEnabled}
        />

        {#if demoState.qualityEnabled}
          <RangeNumber
            label="Quality"
            bind:value={demoState.quality}
            min={controlLimits.quality.min}
            max={controlLimits.quality.max}
            step={controlLimits.quality.step}
          />
        {/if}
      </section>

      <section class="tool-section">
        <div class="accordion-heading">
          <div>
            <h2>Metadata &amp; color</h2>
            <p>{metadataSummary}</p>
          </div>
        </div>

        <label class="switch-field">
          <Switch.Root
            class="switch-root"
            checked={demoState.stripMetadata}
            onCheckedChange={updateStripMetadata}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Strip metadata (sm)</span>
        </label>

        <label class="switch-field">
          <Switch.Root
            class="switch-root"
            bind:checked={demoState.keepCopyright}
            disabled={!demoState.stripMetadata}
          >
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span class:muted-label={!demoState.stripMetadata}>Keep copyright (kcr)</span>
        </label>

        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={demoState.stripColorProfile}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Strip color profile (scp)</span>
        </label>

        <label class="field">
          <span>Color profile (cp)</span>
          <select bind:value={demoState.colorProfile}>
            <option value="none">none</option>
            <option value="srgb">srgb</option>
            <option value="display-p3">display-p3</option>
            <option value="adobe-rgb">adobe-rgb</option>
          </select>
        </label>

        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={demoState.preserveHdr}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Preserve HDR (ph)</span>
        </label>
      </section>
    </div>

    <div class="drawer-actions">
      <button class="quiet-button" type="button" onclick={resetSettings}>Reset</button>
      <button class="copy-button" type="button" onclick={copyUrl}>{copyLabel}</button>
      <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
    </div>
  </aside>

  <section
    class="preview-workspace"
    aria-label="Processed image preview"
    aria-hidden={mobileTools && drawerOpen ? "true" : "false"}
    inert={mobileTools && drawerOpen}
  >
    <header class="preview-command-bar">
      <button
        class="icon-button menu-button"
        type="button"
        aria-label="Open tools"
        bind:this={menuButton}
        onclick={openTools}
      >
        ☰
      </button>
      <code class="parameter-preview">{previewParameters}</code>
      <div class="preview-actions">
        <RadioGroup.Root
          class="theme-toggle"
          value={themeMode}
          onValueChange={setThemeMode}
          orientation="horizontal"
          aria-label="Theme"
        >
          <RadioGroup.Item class="theme-toggle-item" value="light" aria-label="Light theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="4"></circle>
              <path d="M12 2v3"></path>
              <path d="M12 19v3"></path>
              <path d="m4.93 4.93 2.12 2.12"></path>
              <path d="m16.95 16.95 2.12 2.12"></path>
              <path d="M2 12h3"></path>
              <path d="M19 12h3"></path>
              <path d="m4.93 19.07 2.12-2.12"></path>
              <path d="m16.95 7.05 2.12-2.12"></path>
            </svg>
          </RadioGroup.Item>
          <RadioGroup.Item class="theme-toggle-item" value="dark" aria-label="Dark theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M20 14.2A8.2 8.2 0 0 1 9.8 4 8.5 8.5 0 1 0 20 14.2Z"></path>
            </svg>
          </RadioGroup.Item>
          <RadioGroup.Item class="theme-toggle-item" value="system" aria-label="System theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <rect x="4" y="5" width="16" height="11" rx="2"></rect>
              <path d="M9 20h6"></path>
              <path d="M12 16v4"></path>
            </svg>
          </RadioGroup.Item>
        </RadioGroup.Root>
        <div class="desktop-actions">
          <button class="quiet-button" type="button" onclick={resetSettings}>Reset</button>
          <button class="copy-button copy-button-secondary" type="button" onclick={copyUrl}
            >{copyLabel}</button
          >
          <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
        </div>
      </div>
    </header>

    <div class="preview-canvas">
      <div class="preview-metadata" aria-live="polite">
        <span>{sizeLabel}</span>
        <span>{outputLabel}</span>
      </div>
      <div class="image-frame">
        <figure>
          {#if previewImageUrl !== null}
            <img
              class:is-loading={previewLoading}
              src={previewImageUrl}
              alt="Processed sample source"
            />
          {/if}
        </figure>
      </div>
      {#if previewError !== null}
        <div class="preview-error" role="status">{previewError}</div>
      {/if}
      {#if previewLoading}
        <div class="preview-spinner" role="status" aria-label="Loading preview"></div>
      {/if}
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

  :global(.accordion-heading) {
    min-height: 20px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    width: 100%;

    > div {
      min-width: 0;
    }

    :where(h2, p) {
      margin: 0;
    }

    h2 {
      font-size: 16px;
      line-height: 20px;
      font-weight: 600;
      color: var(--text-heading);
    }

    p {
      margin-block-start: 2px;
      color: var(--text-muted);
      font-family: var(--font-mono);
      font-size: 12px;
      line-height: 16px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
  }

  :global(.accordion-heading) {
    border: 0;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    padding: 0;
    text-align: start;
  }

  :global(.collapsible-root) {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  :global(.collapsible-content) {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  :global(.collapsible-content[hidden]) {
    display: none;
  }

  .accordion-chevron {
    width: 8px;
    height: 8px;
    margin-inline-end: 6px;
    flex-shrink: 0;
    border-inline-end: 2px solid currentColor;
    border-block-end: 2px solid currentColor;
    transform: rotate(45deg) translate(-1px, -1px);
    transition: transform 150ms ease;
  }

  :global(.accordion-heading[data-state="closed"]) .accordion-chevron {
    transform: rotate(-45deg);
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
  .drawer-actions,
  .preview-actions {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .preview-actions {
    flex-shrink: 0;
  }

  .preview-actions :global(.theme-toggle) {
    height: 36px;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    padding: 3px;
    border: 1px solid var(--border-strong);
    border-radius: 999px;
    background: var(--surface-button-quiet);
  }

  .preview-actions :global(.theme-toggle-item) {
    width: 28px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 999px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    padding: 0;
  }

  .preview-actions :global(.theme-toggle-item[data-state="checked"]) {
    background: var(--surface-control);
    color: var(--text-heading);
    box-shadow: 0 0 0 1px var(--border-subtle);
  }

  .theme-toggle-icon {
    width: 16px;
    height: 16px;
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-linecap: round;
    stroke-linejoin: round;
    stroke-width: 2;
  }

  .drawer-actions {
    display: none;
  }

  .copy-button,
  .open-link,
  .quiet-button,
  .icon-button {
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    text-decoration: none;
  }

  .copy-button,
  .open-link,
  .quiet-button {
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

  .quiet-button {
    min-width: 76px;
    background: transparent;
    color: var(--text-muted);
  }

  .quiet-button:hover {
    background: var(--surface-button-quiet);
    color: var(--text-heading);
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
    position: relative;
    min-height: 0;
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    padding: 28px;
    background: repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-canvas) 0 50%)
      50% / 20px 20px;
  }

  .preview-metadata {
    position: absolute;
    z-index: 1;
    inset-inline: 28px;
    inset-block-end: 24px;
    display: flex;
    justify-content: space-between;
    gap: 12px;
    color: var(--image-overlay-text);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 16px;
    pointer-events: none;
    text-shadow: var(--image-overlay-shadow);
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
      transition:
        opacity 120ms ease-out,
        filter 120ms ease-out;
    }

    img.is-loading {
      opacity: 0.54;
      filter: saturate(0.82);
    }
  }

  .preview-spinner {
    position: absolute;
    z-index: 2;
    inset-block-start: 50%;
    inset-inline-start: 50%;
    width: 36px;
    height: 36px;
    border: 3px solid color-mix(in srgb, var(--image-overlay-text) 32%, transparent);
    border-block-start-color: var(--accent);
    border-radius: 999px;
    pointer-events: none;
    transform: translate(-50%, -50%);
    animation: preview-spin 650ms linear infinite;
  }

  .preview-error {
    position: absolute;
    z-index: 2;
    inset-inline: 28px;
    inset-block-start: 28px;
    max-width: min(640px, calc(100% - 56px));
    border: 1px solid color-mix(in srgb, var(--danger) 42%, transparent);
    border-radius: 8px;
    background: color-mix(in srgb, var(--surface-bar) 92%, transparent);
    color: var(--danger);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 16px;
    padding: 10px 12px;
    text-wrap: pretty;
    box-shadow: var(--image-shadow);
  }

  @keyframes preview-spin {
    to {
      transform: translate(-50%, -50%) rotate(1turn);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .preview-spinner {
      animation-duration: 1.5s;
    }
  }

  .field,
  .switch-field,
  .focal-picker-field {
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .field-hint {
    margin: 0;
    color: var(--text-muted);
    font-size: 12px;
    line-height: 16px;

    code {
      font-family: var(--font-mono);
      font-size: 11px;
    }
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
    background: repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-control) 0 50%)
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
    box-shadow:
      0 0 0 1px var(--surface-sidebar),
      0 2px 10px rgb(0 0 0 / 0.38);
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

  .background-controls {
    display: flex;
    align-items: start;
    gap: 14px;
  }

  .background-color-field {
    flex: 0 0 58px;
  }

  .background-opacity-field {
    min-width: 0;
    flex: 1;
  }

  .monochrome-control-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    align-items: start;
    gap: 14px;
  }

  .monochrome-color-field {
    width: 58px;
  }

  .duotone-control-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    align-items: start;
    gap: 14px;
  }

  .duotone-color-controls {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }

  .signature-secret-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
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

  /* Segmented control (Simple / Weighted sub-mode tabs) */
  :global(.obj-submode-tabs) {
    display: flex;
    flex-direction: column;
  }

  :global(.obj-submode-list) {
    display: inline-flex;
    height: 32px;
    padding: 3px;
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-control-track);
    gap: 2px;
  }

  :global(.obj-submode-trigger) {
    flex: 1;
    height: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    font-weight: 500;
    line-height: 1;
    padding-inline: 10px;
    transition:
      background-color 120ms ease-out,
      color 120ms ease-out;
  }

  :global(.obj-submode-trigger[data-state="active"]) {
    background: var(--surface-control);
    color: var(--text-heading);
    box-shadow: 0 0 0 1px var(--border-subtle);
  }

  :global(.obj-submode-trigger:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  /* Class multi-select dropdown */
  :global(.obj-class-trigger) {
    min-width: 0;
    width: 100%;
    height: 38px;
    display: inline-flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    padding-inline: 12px 10px;
    font: inherit;
    font-size: 14px;
    line-height: 18px;
    cursor: pointer;
    text-align: start;

    &:focus-visible {
      outline: 2px solid var(--focus-ring);
      outline-offset: 2px;
    }
  }

  .obj-class-trigger-chevron {
    width: 5px;
    height: 5px;
    flex-shrink: 0;
    border-inline-end: 2px solid var(--text-muted);
    border-block-end: 2px solid var(--text-muted);
    transform: rotate(45deg) translate(-1px, -1px);
    margin-inline-end: 4px;
  }

  :global(.obj-class-trigger[data-state="open"]) .obj-class-trigger-chevron {
    transform: rotate(-135deg) translate(-1px, -1px);
  }

  :global(.obj-class-content) {
    min-width: var(--bits-select-anchor-width, 180px);
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-sidebar);
    box-shadow: var(--image-shadow);
    overflow: hidden;
    z-index: 50;
  }

  :global(.obj-class-viewport) {
    padding: 4px;
  }

  :global(.obj-class-item) {
    height: 32px;
    display: flex;
    align-items: center;
    gap: 8px;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    padding-inline: 8px;
    width: 100%;
    text-align: start;

    &:hover,
    &[data-highlighted] {
      background: color-mix(in srgb, var(--accent) 12%, var(--surface-control));
      color: var(--text-heading);
    }

    &[data-selected] {
      color: var(--text-heading);
      font-weight: 500;
    }
  }

  .obj-class-item-check {
    width: 14px;
    flex-shrink: 0;
    color: var(--accent);
    font-size: 12px;
    line-height: 1;
  }

  .text-input {
    min-height: 38px;
    width: 100%;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    padding: 0 12px;
  }

  .text-input-mono {
    font-family: var(--font-mono);
    font-size: 12px;
  }

  .field-error {
    margin: 0;
    color: var(--accent);
    font-size: 12px;
    line-height: 16px;
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

  .muted-label {
    color: var(--text-muted);
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
    transition: background-color 120ms ease-out;
  }

  .fiddle-shell :global(.switch-root[data-state="checked"]) {
    background: var(--accent);
  }

  .fiddle-shell :global(.switch-thumb) {
    display: block;
    width: 20px;
    height: 20px;
    border-radius: 999px;
    background: var(--text-muted);
    transition:
      transform 140ms cubic-bezier(0.2, 0.9, 0.24, 1),
      background-color 120ms ease-out;
  }

  .fiddle-shell :global(.switch-root[data-state="checked"] .switch-thumb) {
    background: var(--surface-sidebar);
    transform: translateX(18px);
  }

  .fiddle-shell :global(.switch-root:focus-visible),
  .fiddle-shell :global(.accordion-heading:focus-visible),
  .fiddle-shell :global(.theme-toggle-item:focus-visible),
  :where(
    .copy-button,
    .open-link,
    .quiet-button,
    .icon-button,
    select,
    .text-input,
    .focal-picker
  ):focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .fiddle-shell :global(.switch-root),
    .fiddle-shell :global(.switch-thumb) {
      transition-duration: 1ms;
    }
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

    .preview-actions {
      margin-inline-start: auto;
      gap: 0;
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

    .preview-metadata {
      inset-inline: 18px;
      inset-block-end: 16px;
      font-size: 11px;
      line-height: 14px;
    }
  }
</style>
