defmodule ImagePipe.SourceTest.CredentialProvider do
  @moduledoc false

  def fetch_credentials(scope, provider_opts, runtime_opts) do
    send(message_target(), {:fetch_credentials, scope, provider_opts, runtime_opts})

    {:ok,
     [
       access_key_id: "AKIA_TEST",
       secret_access_key: "SECRET_TEST",
       token: "TOKEN_TEST"
     ]}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
