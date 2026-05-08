defmodule ImagePlug.Transform.Types do
  @moduledoc false

  @type scalar() :: integer() | float()
  @type pixels() :: {:pixels, scalar()}
  @type pct() :: {:percent, scalar()}
  @type scale() :: {:scale, scalar(), scalar()}
  @type ratio() :: {scalar(), scalar()}
  @type length() :: pixels() | pct() | scale()
end
