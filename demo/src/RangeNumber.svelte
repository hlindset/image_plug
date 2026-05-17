<script lang="ts">
  import { Slider } from "bits-ui";

  export let label: string;
  export let value: number;
  export let min = 0;
  export let max = 100;
  export let step = 1;
  export let suffix: string | undefined = undefined;

  function clamp(value: number): number {
    return Math.min(Math.max(value, min), max);
  }

  function selectNumber(event: FocusEvent): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement) {
      input.select();
    }
  }

  function syncNumber(event: Event): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement && !Number.isNaN(input.valueAsNumber)) {
      value = clamp(input.valueAsNumber);
    }
  }
</script>

<div class="range-number">
  <label class="value-row">
    <span>{label}</span>
    <span class="value-input">
      <input type="number" {min} {max} {step} {value} onfocus={selectNumber} oninput={syncNumber} />
      {#if suffix !== undefined}
        <span class="value-suffix">{suffix}</span>
      {/if}
    </span>
  </label>
  <Slider.Root
    class="slider-root"
    type="single"
    {min}
    {max}
    {step}
    bind:value
    onValueChange={(nextValue) => (value = clamp(nextValue))}
    onValueCommit={(nextValue) => (value = clamp(nextValue))}
  >
    <Slider.Range class="slider-range" />
    <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
  </Slider.Root>
</div>

<style>
  .range-number {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .value-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  .value-input {
    display: inline-flex;
    align-items: baseline;
    gap: 2px;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 18px;
  }

  .value-suffix {
    min-width: 2ch;
    color: var(--text-muted);
  }

  input[type="number"] {
    width: auto;
    min-width: 5ch;
    max-width: 10ch;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--text-primary);
    field-sizing: content;
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 18px;
    padding-inline: 4px;
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

  .range-number :global(.slider-root) {
    position: relative;
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    touch-action: none;
    user-select: none;
  }

  .range-number :global(.slider-root::before) {
    content: "";
    position: absolute;
    inset: 11px 0;
    border-radius: 999px;
    background: var(--surface-control-track);
  }

  .range-number :global(.slider-range) {
    position: absolute;
    height: 6px;
    border-radius: 999px;
    background: var(--accent);
  }

  .range-number :global(.slider-thumb) {
    width: 20px;
    height: 20px;
    border: 2px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--text-primary);
  }

  .range-number :global(.slider-thumb:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
