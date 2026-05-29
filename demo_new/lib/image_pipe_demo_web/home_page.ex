defmodule ImagePipeDemoWeb.HomePage do
  @moduledoc """
  Minimal Hologram page that exercises the ImagePipe plug end to end.

  Each `<img>` points at the plug mounted at `/img` (see the router). The
  imgproxy-style path is `/<signature>/<options...>/plain/<source>`; unsigned
  dev URLs use `_` as the signature, the `plain/` marker introduces a literal
  (non-base64) source path, and sources resolve from `priv/static`.
  """

  use Hologram.Page

  route "/"

  layout ImagePipeDemoWeb.MainLayout

  def template do
    ~HOLO"""
    <div class="ip-page">
      <h1 class="ip-page__title">ImagePipe demo</h1>
      <p class="ip-page__subtitle">
        Each image below is fetched from <code class="ip-card__code">priv/static</code>
        and transformed on the fly by the ImagePipe plug mounted at
        <code class="ip-card__code">/img</code>.
      </p>

      <div class="ip-grid">
        <figure class="ip-card">
          <img
            class="ip-card__image"
            src="/img/_/rs:fit:480:360/plain/images/dog.jpg"
            alt="Dog, resized to fit 480x360"
          />
          <figcaption class="ip-card__caption">
            <code class="ip-card__code">rs:fit:480:360</code> &mdash; fit within 480&times;360
          </figcaption>
        </figure>

        <figure class="ip-card">
          <img
            class="ip-card__image"
            src="/img/_/rs:fill:400:400/plain/images/beach.jpg"
            alt="Beach, cropped to fill 400x400"
          />
          <figcaption class="ip-card__caption">
            <code class="ip-card__code">rs:fill:400:400</code> &mdash; crop to fill 400&times;400
          </figcaption>
        </figure>

        <figure class="ip-card">
          <img
            class="ip-card__image"
            src="/img/_/rs:fit:240:240/plain/images/dog.jpg"
            alt="Dog, resized to fit 240x240"
          />
          <figcaption class="ip-card__caption">
            <code class="ip-card__code">rs:fit:240:240</code> &mdash; small thumbnail
          </figcaption>
        </figure>
      </div>
    </div>
    """
  end
end
