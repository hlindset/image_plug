defmodule ImagePlug.SourceTest.FoobarTranslator do
  @moduledoc false

  def translate(source, _opts) do
    send(self(), {:foobar_translate, source})

    {:ok,
     %ImagePlug.Plan.Source.Object{
       adapter: :foobar,
       scope: "asset",
       key: source,
       revision: nil
     }}
  end
end
