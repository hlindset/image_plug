defmodule ImagePipeDemoWeb.Components.Fiddle.CropTool do
  use Hologram.Component
  alias ImagePipeDemo.Fiddle.SampleImages
  alias ImagePipeDemoWeb.Components.Fiddle.{ToolToggleHeader, CropDimensionControl}

  prop :demo, :any

  def template do
    ~HOLO"""
    <section class="tool-section">
      <ToolToggleHeader
        title="Crop"
        summary={if @demo.crop_enabled do "On" else "Off" end}
        checked={@demo.crop_enabled}
        action={:toggle_crop}
      />
      {%if @demo.crop_enabled}
        <CropDimensionControl
          label="Width"
          unit={@demo.crop_width_unit}
          pixels={@demo.crop_width}
          percent={@demo.crop_width_percent}
          max_pixels={SampleImages.width(@demo.source)}
          unit_action={:set_crop_width_unit}
          value_action={:set_crop_width}
        />
        <CropDimensionControl
          label="Height"
          unit={@demo.crop_height_unit}
          pixels={@demo.crop_height}
          percent={@demo.crop_height_percent}
          max_pixels={SampleImages.height(@demo.source)}
          unit_action={:set_crop_height_unit}
          value_action={:set_crop_height}
        />
        <label class="value-row">
          <span>Gravity</span>
          <select $change={action: :set_crop_gravity, target: "page"}>
            {%for g <- ~w(inherit ce no so ea we noea nowe soea sowe)}
              <option value={g} selected={g == @demo.crop_gravity}>{g}</option>
            {/for}
          </select>
        </label>
      {/if}
    </section>
    """
  end
end
