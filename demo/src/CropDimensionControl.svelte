<script lang="ts">
  import { Slider } from "bits-ui";
  import type { CropDimensionUnit } from "./processing-path";

  export let label: string;
  export let unit: CropDimensionUnit = "px";
  export let pixels: number;
  export let percent: number;
  export let maxPixels = 1200;

  $: activeValue = unit === "percent" ? percent : pixels;
  $: min = 1;
  $: max = unit === "percent" ? 99 : maxPixels;
  $: suffix = unit === "percent" ? "%" : "px";

  function clamp(value: number): number {
    return Math.min(Math.max(value, min), max);
  }

  function selectNumber(event: FocusEvent): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement) {
      input.select();
    }
  }

  function setActiveValue(nextValue: number): void {
    const clamped = clamp(nextValue);

    if (unit === "percent") {
      percent = clamped;
    } else if (unit === "px") {
      pixels = clamped;
    }
  }

  function syncNumber(event: Event): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement && !Number.isNaN(input.valueAsNumber)) {
      setActiveValue(input.valueAsNumber);
    }
  }
</script>

<div class="crop-dimension-control">
  <label class="value-row">
    <span>{label}</span>
    <span class="value-controls">
      {#if unit !== "full"}
        <input
          type="number"
          {min}
          {max}
          step={1}
          value={activeValue}
          aria-label={`${label} value`}
          onfocus={selectNumber}
          oninput={syncNumber}
        />
        <span class="unit-suffix">{suffix}</span>
      {/if}
      <select bind:value={unit} aria-label={`${label} unit`}>
        <option value="px">px</option>
        <option value="percent">%</option>
        <option value="full">full</option>
      </select>
    </span>
  </label>

  {#if unit !== "full"}
    <Slider.Root
      class="slider-root"
      type="single"
      {min}
      {max}
      step={1}
      value={activeValue}
      onValueChange={setActiveValue}
      onValueCommit={setActiveValue}
    >
      <Slider.Range class="slider-range" />
      <Slider.Thumb class="slider-thumb" index={0} />
    </Slider.Root>
  {/if}
</div>

<style>
  .crop-dimension-control {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .value-row,
  .value-controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .value-row {
    justify-content: space-between;
  }

  input[type="number"] {
    width: 56px;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--text-primary);
    font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
    line-height: 18px;
    text-align: right;
    appearance: textfield;
    -moz-appearance: textfield;

    &::-webkit-inner-spin-button,
    &::-webkit-outer-spin-button {
      margin: 0;
      appearance: none;
      -webkit-appearance: none;
    }

    &:hover,
    &:focus {
      border-color: var(--border-strong);
      background: var(--surface-control);
      outline: none;
    }
  }

  .unit-suffix {
    width: 18px;
    color: var(--text-muted);
    font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    text-align: left;
  }

  select {
    width: 74px;
    min-height: 32px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    font: inherit;
    padding: 0 8px;
  }

  .crop-dimension-control :global(.slider-root) {
    position: relative;
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    touch-action: none;
    user-select: none;
  }

  .crop-dimension-control :global(.slider-root::before) {
    content: "";
    position: absolute;
    inset: 11px 0;
    border-radius: 999px;
    background: var(--surface-control-track);
  }

  .crop-dimension-control :global(.slider-range) {
    position: absolute;
    height: 6px;
    border-radius: 999px;
    background: var(--accent);
  }

  .crop-dimension-control :global(.slider-thumb) {
    width: 20px;
    height: 20px;
    border: 2px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--text-primary);
  }

  .crop-dimension-control :global(.slider-thumb:focus-visible),
  select:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
