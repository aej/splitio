defmodule Splitio.Impressions.Listener do
  @moduledoc false

  alias Splitio.Config
  alias Splitio.Models.Impression

  @spec notify(Impression.t(), map()) :: :ok
  def notify(%Impression{} = impression, attributes \\ %{}) do
    case Application.get_env(:splitio, :config) do
      %Config{impression_listener: listener} ->
        call_listener(listener, %{impression: impression, attributes: attributes})

      _ ->
        :ok
    end
  end

  defp call_listener(nil, _payload), do: :ok

  defp call_listener(listener, payload) when is_function(listener, 1) do
    listener.(payload)
    :ok
  rescue
    error ->
      require Logger
      Logger.error("Impression listener failed: #{Exception.message(error)}")
      :ok
  end

  defp call_listener({module, function, extra_args}, payload)
       when is_atom(module) and is_atom(function) and is_list(extra_args) do
    apply(module, function, [payload | extra_args])
    :ok
  rescue
    error ->
      require Logger
      Logger.error("Impression listener failed: #{Exception.message(error)}")
      :ok
  end

  defp call_listener(_listener, _payload), do: :ok
end
