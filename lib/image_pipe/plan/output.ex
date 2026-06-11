defmodule ImagePipe.Plan.Output do
  @moduledoc """
  Requested output intent before runtime format negotiation.

  `strip_metadata`, `keep_copyright`, `color_profile`, and `hdr` are resolved
  values (never `nil`): a parser resolves its config defaults / URL options into
  concrete values before building a plan (the imgproxy parser does this in
  `apply_request_defaults/2`). They drive the encoder's metadata finalize and the
  transform's HDR working-space decision.
  """

  @enforce_keys [:mode]
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            strip_metadata: true,
            keep_copyright: true,
            color_profile: :strip,
            hdr: :tone_map

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: color_profile(),
          hdr: hdr()
        }
end
