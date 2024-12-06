defmodule ImagePlug.TestSupport do
  use ExUnitProperties

  def random_base_unit(opts \\ []) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 9999)

    one_of([
      tuple({constant(:int), integer(min..max)}),
      tuple({constant(:float), float(min: min, max: max)})
    ])
  end

  def random_root_unit(opts \\ []) do
    min = Keyword.get(opts, :min, 0)
    int_min = Keyword.get(opts, :int_min, min)
    int_max = Keyword.get(opts, :int_min, 9999)
    float_min = Keyword.get(opts, :float_min, min)
    float_max = Keyword.get(opts, :float_min, 9999)
    pct_min = Keyword.get(opts, :pct_min, min)
    pct_max = Keyword.get(opts, :pct_min, 9999)
    numerator_min = Keyword.get(opts, :numerator_min, min)
    numerator_max = Keyword.get(opts, :numerator_min, 9999)
    denominator_max = Keyword.get(opts, :denominator_min, 9999)

    one_of([
      tuple({constant(:int), integer(int_min..int_max)}),
      tuple({constant(:float), float(min: float_min, max: float_max)}),
      tuple(
        {constant(:scale), random_base_unit(min: numerator_min, max: numerator_max),
         random_base_unit(min: 1, max: denominator_max)}
      ),
      tuple({constant(:pct), random_base_unit(min: pct_min, max: pct_max)})
    ])
  end

  def x_anchor, do: one_of([constant(:left), constant(:center), constant(:right)])
  def y_anchor, do: one_of([constant(:top), constant(:center), constant(:bottom)])

  def focus_type do
    one_of([
      tuple({constant(:coordinate), random_root_unit(), random_root_unit()}),
      tuple({constant(:anchor), x_anchor(), y_anchor()})
    ])
  end

  def crop_from do
    one_of([
      constant(:focus),
      fixed_map(%{
        left: random_root_unit(),
        top: random_root_unit()
      })
    ])
  end
end
