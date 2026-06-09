defmodule ImagePipeDemoWeb.Components.Fiddle.CommandBar do
  use Hologram.Component

  prop :path, :string
  prop :image_url, :string

  def template do
    ~HOLO"""
    <header class="preview-command-bar">
      <code class="parameter-preview">{@path}</code>
      <div class="preview-actions">
        <div class="desktop-actions">
          <button class="copy-button copy-button-secondary" type="button" $click={action: :copy_url, target: "page"}>Copy URL</button>
          <a class="open-link" href={@image_url} target="_blank" rel="noreferrer">Open</a>
        </div>
      </div>
    </header>
    """
  end
end
