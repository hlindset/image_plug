defmodule ImagePipe.Output.Resolved do
  @moduledoc false

  @enforce_keys [
    :format,
    :quality,
    :response_headers,
    :strip_metadata,
    :keep_copyright,
    :strip_color_profile
  ]
  defstruct @enforce_keys

  @type format :: ImagePipe.Format.output_format()
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          format: format(),
          quality: quality(),
          response_headers: [{String.t(), String.t()}],
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          strip_color_profile: boolean()
        }
end
