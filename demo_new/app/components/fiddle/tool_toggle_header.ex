defmodule ImagePipeDemoWeb.Components.Fiddle.ToolToggleHeader do
  use Hologram.Component

  prop :title, :string
  prop :summary, :string
  prop :checked, :boolean
  prop :action, :atom

  def template do
    ~HOLO"""
    <button
      class={"tool-toggle-heading #{if @checked, do: "is-checked", else: ""}"}
      type="button"
      $click={action: @action, target: "page"}
    >
      <span>
        <h2>{@title}</h2>
        <p>{@summary}</p>
      </span>
      <span class="switch-root" aria-hidden="true">
        <span class="switch-thumb"></span>
      </span>
    </button>
    """
  end
end
