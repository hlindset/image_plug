<script lang="ts">
  import { Slider } from "bits-ui";

  export let label: string;
  export let value: number;
  export let min = 0;
  export let max = 100;
  export let step = 1;

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
    <input
      type="number"
      {min}
      {max}
      {step}
      value={value}
      onfocus={selectNumber}
      oninput={syncNumber}
    />
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
    <Slider.Thumb class="slider-thumb" index={0} />
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
    justify-content: space-between;
    gap: 12px;
  }

  input[type="number"] {
    width: 72px;
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
