defmodule ImagePlug.ParamParser.Twicpics.UtilsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.ParamParser.Twicpics.Utils

  test "balanced_parens?/1" do
    assert Utils.balanced_parens?("(") == false
    assert Utils.balanced_parens?(")") == false
    assert Utils.balanced_parens?("(()") == false
    assert Utils.balanced_parens?("())") == false
    assert Utils.balanced_parens?("(((()))") == false
    assert Utils.balanced_parens?("((())))") == false

    assert Utils.balanced_parens?("") == true
    assert Utils.balanced_parens?("()") == true
    assert Utils.balanced_parens?("(())") == true
    assert Utils.balanced_parens?("((()))") == true
  end
end
