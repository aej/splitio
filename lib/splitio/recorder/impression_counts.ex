defmodule Splitio.Recorder.ImpressionCounts do
  @moduledoc """
  Impression counts recorder - flushes aggregated counts to API.
  """

  use GenServer

  alias Splitio.Api.Events, as: EventsApi
  alias Splitio.Config
  alias Splitio.Impressions.Counter

  require Logger

  defstruct [
    :config,
    :flush_timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Flush counts"
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{config: config}
    state = schedule_flush(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state.config)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush(state.config)
    state = schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state.config)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_flush(config) do
    counts = Counter.pop_counts()

    if map_size(counts) > 0 do
      payload = format_counts_payload(counts)

      case EventsApi.post_impression_counts(config, payload) do
        {:ok, _} ->
          Logger.debug("Flushed #{map_size(counts)} impression counts")

        {:error, reason} ->
          Logger.error("Failed to flush impression counts: #{inspect(reason)}")
      end
    end
  end

  defp format_counts_payload(counts) do
    pf =
      Enum.map(counts, fn {{feature, hour}, count} ->
        %{"f" => feature, "m" => hour, "rc" => count}
      end)

    %{"pf" => pf}
  end

  defp schedule_flush(state) do
    interval_ms = state.config.impressions_refresh_rate * 1000
    timer = Process.send_after(self(), :flush, interval_ms)
    %{state | flush_timer: timer}
  end
end
