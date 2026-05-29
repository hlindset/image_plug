defmodule ImagePipeDemoWeb.Components.Fiddle.CropDimensionControl do
  use Hologram.Component

  prop :label, :string
  prop :unit, :atom
  prop :pixels, :integer
  prop :percent, :integer
  prop :max_pixels, :integer
  prop :unit_action, :atom
  prop :value_action, :atom

  def template do
    ~HOLO"""
    <div class="crop-dimension-control">
      <label class="value-row">
        <span>{@label}</span>
        <span class="value-controls">
          {%if @unit != :full}
            <input
              type="number"
              min="1"
              max={if @unit == :percent do 99 else @max_pixels end}
              step="1"
              value={if @unit == :percent do @percent else @pixels end}
              $change={action: @value_action, target: "page"}
            />
            <span class="unit-suffix">{if @unit == :percent do "%" else "px" end}</span>
          {/if}
          <select $change={action: @unit_action, target: "page"}>
            <option value="px" selected={@unit == :px}>px</option>
            <option value="percent" selected={@unit == :percent}>%</option>
            <option value="full" selected={@unit == :full}>full</option>
          </select>
        </span>
      </label>
      {%if @unit != :full}
        <input
          type="range"
          class="ip-range"
          min="1"
          max={if @unit == :percent do 99 else @max_pixels end}
          step="1"
          value={if @unit == :percent do @percent else @pixels end}
          $change={action: @value_action, target: "page"}
        />
      {/if}
    </div>
    """
  end
end
