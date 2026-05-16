<script lang="ts">
  import { Switch } from "bits-ui";

  export let title: string;
  export let summary: string;
  export let checked: boolean;

  function toggleChecked(): void {
    checked = !checked;
  }
</script>

<button class="tool-toggle-heading" type="button" aria-pressed={checked} onclick={toggleChecked}>
  <span>
    <h2>{title}</h2>
    <p>{summary}</p>
  </span>
  <Switch.Root
    class="switch-root"
    aria-label={`${checked ? "Disable" : "Enable"} ${title.toLowerCase()}`}
    bind:checked
    onpointerdown={(event) => event.stopPropagation()}
    onclick={(event) => event.stopPropagation()}
  >
    <Switch.Thumb class="switch-thumb" />
  </Switch.Root>
</button>

<style>
  .tool-toggle-heading {
    min-height: 20px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    border: 0;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    padding: 0;
    text-align: start;

    :where(h2, p) {
      margin: 0;
    }

    h2 {
      color: var(--text-heading);
      font-size: 16px;
      font-weight: 650;
      line-height: 20px;
    }

    p {
      margin-block-start: 2px;
      color: var(--text-muted);
      font-size: 12px;
      line-height: 16px;
    }

    &:focus-visible {
      border-radius: 6px;
      outline: 2px solid var(--focus-ring);
      outline-offset: 4px;
    }
  }
</style>
