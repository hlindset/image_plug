defmodule ImagePipe.SourceTest.FoobarTranslator do
  @moduledoc false

  def translate(source, _opts) do
    send(self(), {:foobar_translate, source})

    {:ok,
     %ImagePipe.Plan.Source.Object{
       adapter: :foobar,
       scope: "asset",
       key: source,
       revision: nil
     }}
  end
end
