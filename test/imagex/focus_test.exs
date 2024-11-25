defmodule Imagex.FocusTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Imagex.Transform.Focus

  test "crop parameters parser" do
    check all left <- integer(0..9999),
              top <- integer(0..9999) do
      str_params = "#{left}x#{top}"
      parsed = Focus.Parameters.parse(str_params)
      assert {:ok, %Focus.Parameters{left: left, top: top}} == parsed
    end
  end
end
