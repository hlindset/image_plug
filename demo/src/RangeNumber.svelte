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
