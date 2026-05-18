defmodule ImagePlug.SourceTest.CredentialProvider do
  @moduledoc false

  def fetch_credentials(scope, provider_opts, runtime_opts) do
    send(self(), {:fetch_credentials, scope, provider_opts, runtime_opts})

    {:ok,
     [
       access_key_id: "AKIA_TEST",
       secret_access_key: "SECRET_TEST",
       token: "TOKEN_TEST"
     ]}
  end
end
