defmodule ImagePipeDemoWeb.Components.Fiddle.PreviewCanvas do
  use Hologram.Component

  prop :object_url, :string
  prop :loading, :boolean
  prop :error, :string
  prop :size_label, :string
  prop :output_label, :string

  def template do
    ~HOLO"""
    <div class="preview-canvas">
      <div class="preview-metadata">
        <span>{@size_label}</span>
        <span>{@output_label}</span>
      </div>
      <div class="image-frame">
        {%if @object_url}
          <figure>
            <img class={"#{if @loading, do: "is-loading", else: ""}"} src={@object_url} />
          </figure>
        {/if}
      </div>
      {%if @error}
        <div class="preview-error">{@error}</div>
      {/if}
      {%if @loading}
        <div class="preview-spinner"></div>
      {/if}
    </div>
    """
  end
end
