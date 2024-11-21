defmodule Imagex.Repo do
  use Ecto.Repo,
    otp_app: :imagex,
    adapter: Ecto.Adapters.Postgres
end
