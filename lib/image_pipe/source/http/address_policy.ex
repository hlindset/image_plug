defmodule ImagePipe.Source.HTTP.AddressPolicy do
  @moduledoc false

  @type category ::
          :loopback
          | :unspecified
          | :link_local
          | :private
          | :unique_local
          | :multicast
          | :broadcast
          | :cgnat
          | :reserved
          | :public

  @spec classify(:inet.ip_address()) :: category()
  def classify({a, b, c, d}) do
    classify_v4(a, b, c, d)
  end

  defp classify_v4(0, _, _, _), do: :unspecified
  defp classify_v4(127, _, _, _), do: :loopback
  defp classify_v4(169, 254, _, _), do: :link_local
  defp classify_v4(10, _, _, _), do: :private
  defp classify_v4(172, b, _, _) when b in 16..31, do: :private
  defp classify_v4(192, 168, _, _), do: :private
  defp classify_v4(100, b, _, _) when b in 64..127, do: :cgnat
  defp classify_v4(a, _, _, _) when a in 224..239, do: :multicast
  defp classify_v4(255, 255, 255, 255), do: :broadcast
  # benchmarking 198.18.0.0/15
  defp classify_v4(198, b, _, _) when b in 18..19, do: :reserved
  # documentation 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
  defp classify_v4(192, 0, 2, _), do: :reserved
  defp classify_v4(198, 51, 100, _), do: :reserved
  defp classify_v4(203, 0, 113, _), do: :reserved
  # 240.0.0.0/4 reserved (future use)
  defp classify_v4(a, _, _, _) when a in 240..255, do: :reserved
  defp classify_v4(_, _, _, _), do: :public
end
