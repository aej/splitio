defmodule Splitio.Push.Processor do
  @moduledoc """
  SSE event processor.

  Routes events to appropriate handlers:
  - Split updates -> Sync splits
  - Segment updates -> Sync segments
  - Control messages -> Sync manager
  - Occupancy -> Track publishers
  """

  alias Splitio.Push.Messages.{
    SplitUpdate,
    SplitKill,
    SegmentUpdate,
    RuleBasedSegmentUpdate,
    LargeSegmentUpdate,
    Control,
    Occupancy
  }

  alias Splitio.Sync.{Splits, Segments, LargeSegments, Manager}
  alias Splitio.Storage
  alias Splitio.Models.Split

  require Logger

  # Track occupancy per control channel
  @control_channels [:control_pri, :control_sec]

  @doc """
  Handle an SSE event.
  """
  @spec handle_event(term()) :: :ok
  def handle_event(%SplitUpdate{} = event) do
    Logger.debug("Split update: cn=#{event.change_number}")

    current_cn = Storage.get_splits_change_number()

    cond do
      event.change_number <= current_cn ->
        # Already have this or newer
        :ok

      event.previous_change_number == current_cn and event.definition != nil ->
        # Optimistic update - apply inline definition
        apply_inline_split(event)

      true ->
        # Need to fetch from API
        config = Application.get_env(:splitio, :config)

        if config do
          Splits.sync_to(config, event.change_number)
        end
    end

    :ok
  end

  def handle_event(%SplitKill{} = event) do
    Logger.info("Split killed: #{event.split_name}")

    case Storage.get_split(event.split_name) do
      {:ok, split} ->
        killed_split = %{split | killed: true, default_treatment: event.default_treatment}
        Storage.put_split(killed_split)

      :not_found ->
        :ok
    end

    # Emit SDK_UPDATE event
    :telemetry.execute([:splitio, :sdk, :update], %{}, %{type: :split_kill})
    :ok
  end

  def handle_event(%SegmentUpdate{} = event) do
    Logger.debug("Segment update: #{event.segment_name} cn=#{event.change_number}")

    current_cn = Storage.get_segment_change_number(event.segment_name)

    if event.change_number > current_cn do
      config = Application.get_env(:splitio, :config)

      if config do
        Segments.sync_segment_to(config, event.segment_name, event.change_number)
      end
    end

    :ok
  end

  def handle_event(%RuleBasedSegmentUpdate{} = event) do
    Logger.debug("Rule-based segment update: cn=#{event.change_number}")

    current_cn = Storage.get_rule_based_segments_change_number()

    if event.change_number > current_cn do
      # Rule-based segments sync with splits
      config = Application.get_env(:splitio, :config)

      if config do
        Splits.sync(config)
      end
    end

    :ok
  end

  def handle_event(%LargeSegmentUpdate{} = event) do
    Logger.debug("Large segment update: #{event.name}")

    config = Application.get_env(:splitio, :config)

    if config do
      LargeSegments.sync_large_segment(config, event.name)
    end

    :ok
  end

  def handle_event(%Control{control_type: type}) do
    Logger.info("Streaming control: #{type}")

    case type do
      :streaming_enabled ->
        Manager.start_streaming()

      :streaming_paused ->
        Manager.start_polling()

      :streaming_disabled ->
        Manager.start_polling()
    end

    :ok
  end

  def handle_event(%Occupancy{channel: channel, publishers: publishers}) do
    Logger.debug("Occupancy #{channel}: #{publishers}")

    # Store occupancy
    :persistent_term.put({__MODULE__, :occupancy, channel}, publishers)

    # Check if all control channels have 0 publishers
    if all_control_channels_empty?() do
      Logger.warning("All control channels have 0 publishers, switching to polling")
      Manager.start_polling()
    end

    :ok
  end

  def handle_event(unknown) do
    Logger.debug("Unknown SSE event: #{inspect(unknown)}")
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp apply_inline_split(%SplitUpdate{definition: definition, compression: compression}) do
    data =
      definition
      |> Base.decode64!()
      |> decompress(compression)

    case Jason.decode(data) do
      {:ok, json} ->
        case Split.from_json(json) do
          {:ok, split} ->
            Storage.put_split(split)
            :telemetry.execute([:splitio, :sdk, :update], %{}, %{type: :split_update})

          {:error, _} ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp decompress(data, :none), do: data
  defp decompress(data, :gzip), do: :zlib.gunzip(data)
  defp decompress(data, :zlib), do: :zlib.uncompress(data)

  defp all_control_channels_empty? do
    Enum.all?(@control_channels, fn channel ->
      case :persistent_term.get({__MODULE__, :occupancy, channel}, nil) do
        nil -> false
        0 -> true
        _ -> false
      end
    end)
  end
end
