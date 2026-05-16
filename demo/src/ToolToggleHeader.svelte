<script lang="ts">
  export let title: string;
  export let summary: string;
  export let checked: boolean;
  export let onCheckedChange: ((checked: boolean) => void) | undefined = undefined;

  function toggleChecked(): void {
    const nextChecked = !checked;

    checked = nextChecked;
    onCheckedChange?.(nextChecked);
  }
</script>

<button
  class="tool-toggle-heading"
  class:is-checked={checked}
  type="button"
  aria-pressed={checked}
  aria-label={`${checked ? "Disable" : "Enable"} ${title.toLowerCase()}`}
  onclick={toggleChecked}
>
  <span>
    <h2>{title}</h2>
    <p>{summary}</p>
  </span>
  <span class="switch-root" aria-hidden="true">
    <span class="switch-thumb"></span>
  </span>
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
      font-family: var(--font-mono);
      font-size: 12px;
      line-height: 16px;
    }

    &:focus-visible {
      border-radius: 6px;
      outline: 2px solid var(--focus-ring);
      outline-offset: 4px;
    }
  }

  .switch-root {
    width: 42px;
    height: 24px;
    display: flex;
    flex-shrink: 0;
    align-items: center;
    justify-content: flex-start;
    border-radius: 999px;
    background: var(--surface-control-track);
    padding: 2px;
  }

  .switch-thumb {
    display: block;
    width: 20px;
    height: 20px;
    border-radius: 999px;
    background: var(--text-muted);
  }

  .tool-toggle-heading.is-checked .switch-root {
    justify-content: flex-end;
    background: var(--accent);
  }

  .tool-toggle-heading.is-checked .switch-thumb {
    background: var(--surface-sidebar);
  }
</style>
