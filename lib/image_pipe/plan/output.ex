defmodule ImagePipe.Plan.Output do
  @moduledoc """
  Requested output intent before runtime format negotiation.

  `strip_metadata`, `keep_copyright`, and `strip_color_profile` are resolved
  booleans (never `nil`): a parser resolves its config defaults / URL options
  into concrete values before building a plan (the imgproxy parser does this in
  `apply_request_defaults/2`). They drive the encoder's metadata finalize.
  """

  @enforce_keys [:mode]
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            strip_metadata: true,
            keep_copyright: true,
            strip_color_profile: true

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          strip_color_profile: boolean()
        }
end
