defmodule Splitio.Push.Parser do
  @moduledoc """
  SSE message parser.

  Parses Server-Sent Events from Ably streaming connection.
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

  require Logger

  @type event ::
          SplitUpdate.t()
          | SplitKill.t()
          | SegmentUpdate.t()
          | RuleBasedSegmentUpdate.t()
          | LargeSegmentUpdate.t()
          | Control.t()
          | Occupancy.t()

  @doc """
  Parse SSE data lines into events.

  Returns list of parsed events and remaining buffer.
  """
  @spec parse(binary()) :: {[event()], binary()}
  def parse(data) do
    parse_lines(data, [], %{})
  end

  defp parse_lines(data, events, current_event) do
    case String.split(data, "\n", parts: 2) do
      [line, rest] ->
        {events, current_event} = process_line(line, events, current_event)
        parse_lines(rest, events, current_event)

      [incomplete] ->
        # Return incomplete data as buffer
        {Enum.reverse(events), incomplete}
    end
  end

  defp process_line("", events, current_event) do
    # Empty line = end of event
    if map_size(current_event) > 0 do
      case parse_event(current_event) do
        {:ok, event} -> {[event | events], %{}}
        :skip -> {events, %{}}
      end
    else
      {events, %{}}
    end
  end

  defp process_line(":" <> _comment, events, current_event) do
    # Comment line (keepalive)
    {events, current_event}
  end

  defp process_line(line, events, current_event) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        value = String.trim_leading(value, " ")
        current_event = Map.put(current_event, field, value)
        {events, current_event}

      [field] ->
        current_event = Map.put(current_event, field, "")
        {events, current_event}
    end
  end

  defp parse_event(%{"event" => "message", "data" => data}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_message(json)

      {:error, _} ->
        Logger.warning("Failed to decode SSE message data")
        :skip
    end
  end

  defp parse_event(%{"event" => "[meta]occupancy", "data" => data}) do
    case Jason.decode(data) do
      {:ok, %{"metrics" => %{"publishers" => publishers}}} ->
        {:ok, %Occupancy{channel: "control", publishers: publishers}}

      _ ->
        :skip
    end
  end

  defp parse_event(_), do: :skip

  defp parse_message(%{"data" => inner_data} = json) when is_binary(inner_data) do
    # Nested JSON in data field
    case Jason.decode(inner_data) do
      {:ok, inner_json} ->
        channel = json["channel"] || ""
        parse_notification(inner_json, channel)

      {:error, _} ->
        :skip
    end
  end

  defp parse_message(json) do
    channel = json["channel"] || ""
    parse_notification(json, channel)
  end

  defp parse_notification(%{"type" => "SPLIT_UPDATE"} = json, _channel) do
    {:ok,
     %SplitUpdate{
       change_number: json["changeNumber"],
       previous_change_number: json["pcn"],
       definition: json["d"],
       compression: parse_compression(json["c"])
     }}
  end

  defp parse_notification(%{"type" => "SPLIT_KILL"} = json, _channel) do
    {:ok,
     %SplitKill{
       change_number: json["changeNumber"],
       split_name: json["splitName"],
       default_treatment: json["defaultTreatment"]
     }}
  end

  defp parse_notification(%{"type" => "SEGMENT_UPDATE"} = json, _channel) do
    {:ok,
     %SegmentUpdate{
       change_number: json["changeNumber"],
       segment_name: json["segmentName"]
     }}
  end

  defp parse_notification(%{"type" => "RB_SEGMENT_UPDATE"} = json, _channel) do
    {:ok,
     %RuleBasedSegmentUpdate{
       change_number: json["changeNumber"],
       previous_change_number: json["pcn"],
       definition: json["d"],
       compression: parse_compression(json["c"])
     }}
  end

  defp parse_notification(%{"type" => "LS_DEFINITION_UPDATE", "ls" => segments}, _channel)
       when is_list(segments) do
    # Large segment updates come as array
    events =
      Enum.map(segments, fn seg ->
        %LargeSegmentUpdate{
          name: seg["n"],
          notification_type: parse_ls_type(seg["t"]),
          change_number: seg["cn"],
          spec_version: seg["v"],
          rfd: seg["rfd"]
        }
      end)

    # Return first one for now (processor should handle all)
    case events do
      [first | _] -> {:ok, first}
      [] -> :skip
    end
  end

  defp parse_notification(%{"type" => "CONTROL", "controlType" => control_type}, _channel) do
    {:ok,
     %Control{
       control_type: parse_control_type(control_type)
     }}
  end

  defp parse_notification(%{"metrics" => %{"publishers" => publishers}}, channel) do
    {:ok, %Occupancy{channel: channel, publishers: publishers}}
  end

  defp parse_notification(json, _channel) do
    Logger.debug("Unknown SSE notification: #{inspect(json)}")
    :skip
  end

  defp parse_compression(0), do: :none
  defp parse_compression(1), do: :gzip
  defp parse_compression(2), do: :zlib
  defp parse_compression(_), do: :none

  defp parse_control_type("STREAMING_ENABLED"), do: :streaming_enabled
  defp parse_control_type("STREAMING_PAUSED"), do: :streaming_paused
  defp parse_control_type("STREAMING_DISABLED"), do: :streaming_disabled
  defp parse_control_type(_), do: :streaming_disabled

  defp parse_ls_type("LS_NEW_DEFINITION"), do: :new_definition
  defp parse_ls_type("LS_EMPTY"), do: :empty
  defp parse_ls_type(_), do: :empty
end
