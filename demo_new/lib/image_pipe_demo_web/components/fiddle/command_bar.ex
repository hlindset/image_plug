defmodule ImagePipeDemoWeb.Components.Fiddle.CommandBar do
  use Hologram.Component

  prop :path, :string
  prop :image_url, :string

  def template do
    ~HOLO"""
    <div class="preview-command-bar">
      <code>{@path}</code>
      <span>
        <button type="button" $click={action: :copy_url, target: "page"}>Copy URL</button>
        <a href={@image_url} target="_blank" rel="noopener">Open</a>
      </span>
    </div>
    """
  end
end
