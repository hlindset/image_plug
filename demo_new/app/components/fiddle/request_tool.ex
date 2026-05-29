defmodule ImagePipeDemoWeb.Components.Fiddle.RequestTool do
  use Hologram.Component
  alias ImagePipeDemo.Fiddle.SampleImages

  prop :source, :string
  prop :open, :boolean

  def template do
    ~HOLO"""
    <section class="tool-section">
      <button type="button" class="tool-toggle-heading" $click={action: :toggle_request, target: "page"}>
        <span><h2>Request</h2><p>{@source}</p></span>
      </button>
      {%if @open}
        <label class="value-row">
          <span>Source image</span>
          <select $change={action: :update_source, target: "page"}>
            {%for image <- SampleImages.all()}
              <option value={image.path} selected={image.path == @source}>{image.path}</option>
            {/for}
          </select>
        </label>
      {/if}
    </section>
    """
  end
end
