defmodule Splitio.Recorder.Impressions do
  @moduledoc """
  Impression recorder - queues and flushes impressions to API.
  """

  use GenServer

  alias Splitio.Api.Events, as: EventsApi
  alias Splitio.Config
  alias Splitio.Models.Impression
  alias Splitio.Impressions.{Observer, Counter}

  require Logger

  defstruct [
    :config,
    :queue,
    :flush_timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Record an impression"
  @spec record(Impression.t()) :: :ok | {:error, :queue_full}
  def record(%Impression{} = impression) do
    GenServer.call(__MODULE__, {:record, impression})
  end

  @doc "Flush all queued impressions"
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{
      config: config,
      queue: :queue.new()
    }

    state = schedule_flush(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:record, impression}, _from, state) do
    queue_size = :queue.len(state.queue)

    if queue_size >= state.config.impressions_queue_size do
      Logger.warning("Impression queue full, dropping impression")
      {:reply, {:error, :queue_full}, state}
    else
      # Deduplication based on mode
      {impression, should_queue} = process_impression(impression, state.config.impressions_mode)

      state =
        if should_queue do
          %{state | queue: :queue.in(impression, state.queue)}
        else
          state
        end

      # Check if we should flush
      state =
        if :queue.len(state.queue) >= state.config.impressions_bulk_size do
          do_flush(state)
        else
          state
        end

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = do_flush(state)
    state = schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp process_impression(impression, :debug) do
    # Debug mode: send all impressions
    {impression, true}
  end

  defp process_impression(impression, :none) do
    # None mode: only count, never send
    Counter.increment(impression.feature, impression.time)
    {impression, false}
  end

  defp process_impression(impression, :optimized) do
    # Optimized mode: deduplicate
    impression = Observer.test_and_set(impression)
    Counter.increment(impression.feature, impression.time)

    # Send if first time or first in current hour, or has properties
    should_send = Observer.should_send?(impression) or not is_nil(impression.properties)
    {impression, should_send}
  end

  defp do_flush(%{queue: queue, config: config} = state) do
    impressions = :queue.to_list(queue)

    if length(impressions) > 0 do
      payload = format_bulk_payload(impressions)

      case EventsApi.post_impressions(config, payload, config.impressions_mode) do
        {:ok, _} ->
          Logger.debug("Flushed #{length(impressions)} impressions")

        {:error, reason} ->
          Logger.error("Failed to flush impressions: #{inspect(reason)}")
      end
    end

    %{state | queue: :queue.new()}
  end

  defp format_bulk_payload(impressions) do
    impressions
    |> Enum.group_by(& &1.feature)
    |> Enum.map(fn {feature, imps} ->
      %{
        "f" => feature,
        "i" => Enum.map(imps, &Impression.to_api_format/1)
      }
    end)
  end

  defp schedule_flush(state) do
    interval_ms = state.config.impressions_refresh_rate * 1000
    timer = Process.send_after(self(), :flush, interval_ms)
    %{state | flush_timer: timer}
  end
end
