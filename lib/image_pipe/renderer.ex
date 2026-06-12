defmodule ImagePipe.Renderer do
  @moduledoc """
  Behaviour + dispatch facade for non-image terminal renderers. A renderer module
  declares which expensive pipeline stages it needs (`requires/1`) and formats a
  complete response body (`render/3`) over a neutral `ImagePipe.Plan.RenderContext`.
  The plan carries the renderer module itself (`%Plan.Render{module: ...}`); the core
  never enumerates renderers. `run/3`/`requires/1` are the only places the behaviour
  is invoked.
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Plan.Render
  alias ImagePipe.Plan.RenderContext

  @type need :: :header
  @type body :: {content_type :: String.t(), iodata()}

  @callback requires(params :: map()) :: [need()]
  @callback render(RenderContext.t(), params :: map(), keyword()) ::
              {:ok, body()} | {:error, term()}

  @spec requires(Render.t()) :: [need()]
  def requires(%Render{module: module, params: params}), do: module.requires(params)

  @spec run(Render.t(), RenderContext.t(), keyword()) :: {:ok, body()} | {:error, term()}
  def run(%Render{module: module, params: params}, %RenderContext{} = context, opts),
    do: module.render(context, params, opts)
end
