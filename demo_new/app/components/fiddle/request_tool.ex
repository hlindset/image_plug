defmodule ImagePipeDemoWeb.Components.Fiddle.RequestTool do
  use Hologram.Component
  alias ImagePipeDemo.Fiddle.SampleImages

  prop :source, :string
  prop :open, :boolean

  def template do
    ~HOLO"""
    <section class="tool-section">
      <div class="collapsible-root">
        <button
          type="button"
          class="accordion-heading"
          data-state={if @open do "open" else "closed" end}
          $click={action: :toggle_request, target: "page"}
        >
          <div>
            <h2>Request</h2>
            <p>{@source}</p>
          </div>
          <span class="accordion-chevron" aria-hidden="true"></span>
        </button>
        {%if @open}
          <div class="collapsible-content">
            <label class="field">
              <span>Source image</span>
              <select $change={action: :update_source, target: "page"}>
                {%for image <- SampleImages.all()}
                  <option value={image.path} selected={image.path == @source}>{image.path}</option>
                {/for}
              </select>
            </label>
          </div>
        {/if}
      </div>
    </section>
    """
  end
end
