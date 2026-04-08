defmodule Splitio.Recorder.UniqueKeys do
  @moduledoc false

  use GenServer

  alias Splitio.Api.Events, as: EventsApi
  alias Splitio.Config
  alias Splitio.Impressions.UniqueKeys

  require Logger

  defstruct [:config, :flush_timer]

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{config: config}
    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state.config)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush(state.config)
    {:noreply, schedule_flush(state)}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state.config)
    :ok
  end

  defp do_flush(%Config{impressions_mode: :none} = config) do
    unique_keys = UniqueKeys.pop_keys()

    if map_size(unique_keys) > 0 do
      payload = %{"keys" => Enum.map(unique_keys, &format_feature_keys/1)}

      case EventsApi.post_unique_keys(config, payload) do
        {:ok, _} ->
          Logger.debug("Flushed #{map_size(unique_keys)} unique key groups")

        {:error, reason} ->
          Logger.error("Failed to flush unique keys: #{inspect(reason)}")
      end
    end
  end

  defp do_flush(_config), do: :ok

  defp format_feature_keys({feature, keys}) do
    %{"f" => feature, "ks" => keys |> MapSet.to_list() |> Enum.sort()}
  end

  defp schedule_flush(state) do
    timer = Process.send_after(self(), :flush, state.config.impressions_refresh_rate * 1000)
    %{state | flush_timer: timer}
  end
end
