defmodule Splitio.Sync.Splits do
  @moduledoc """
  Split synchronization from SDK API.

  Handles initial bootstrap and incremental updates.
  """

  alias Splitio.Api.SDK
  alias Splitio.Config
  alias Splitio.Storage
  alias Splitio.Models.{Split, RuleBasedSegment}

  require Logger

  @doc """
  Synchronize splits from API.

  Fetches all changes since the last known change number.
  Returns {:ok, segment_names} with list of referenced segments.
  """
  @spec sync(Config.t()) :: {:ok, [String.t()]} | {:error, term()}
  def sync(%Config{} = config) do
    since = Storage.get_splits_change_number()
    sync_from(config, since, MapSet.new())
  end

  @doc """
  Force sync to a specific change number (CDN bypass).
  """
  @spec sync_to(Config.t(), integer()) :: {:ok, [String.t()]} | {:error, term()}
  def sync_to(%Config{} = config, till) do
    since = Storage.get_splits_change_number()
    sync_with_till(config, since, till, MapSet.new())
  end

  defp sync_from(config, since, segments) do
    case SDK.fetch_split_changes(config, since: since, sets: config.flag_sets_filter) do
      {:ok, response} ->
        {new_segments, till} = process_response(response)
        all_segments = MapSet.union(segments, new_segments)

        # Continue fetching if more changes exist
        if since < till do
          sync_from(config, till, all_segments)
        else
          {:ok, MapSet.to_list(all_segments)}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch split changes: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_with_till(config, since, till, segments) do
    case SDK.fetch_split_changes(config, since: since, till: till, sets: config.flag_sets_filter) do
      {:ok, response} ->
        {new_segments, response_till} = process_response(response)
        all_segments = MapSet.union(segments, new_segments)

        # Continue if still not at target
        if response_till < till do
          sync_with_till(config, response_till, till, all_segments)
        else
          {:ok, MapSet.to_list(all_segments)}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch split changes (CDN bypass): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_response(response) do
    # Extract splits
    splits_data = response["splits"] || response["ff"]["d"] || []
    till = response["till"] || response["ff"]["t"] || -1

    segments =
      Enum.reduce(splits_data, MapSet.new(), fn split_json, acc ->
        case Split.from_json(split_json) do
          {:ok, %Split{status: :active} = split} ->
            Storage.put_split(split)
            extract_segments(split, acc)

          {:ok, %Split{status: :archived, name: name}} ->
            Storage.delete_split(name)
            acc

          {:error, reason} ->
            Logger.warning("Failed to parse split: #{inspect(reason)}")
            acc
        end
      end)

    # Process rule-based segments if present
    rbs_data = response["ruleBasedSegments"] || %{}
    process_rule_based_segments(rbs_data)

    Storage.set_splits_change_number(till)

    {segments, till}
  end

  # Extract segment names from split conditions
  defp extract_segments(%Split{} = split, segments) do
    split.conditions
    |> Enum.flat_map(fn condition ->
      condition.matcher_group.matchers
      |> Enum.flat_map(fn matcher ->
        case matcher.matcher_type do
          :in_segment -> [matcher.segment_name]
          _ -> []
        end
      end)
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> MapSet.union(segments)
  end

  defp process_rule_based_segments(%{"d" => rbs_list, "t" => till}) when is_list(rbs_list) do
    Enum.each(rbs_list, fn rbs_json ->
      case RuleBasedSegment.from_json(rbs_json) do
        {:ok, %RuleBasedSegment{status: :active} = rbs} ->
          Storage.put_rule_based_segment(rbs)

        {:ok, %RuleBasedSegment{status: :archived, name: name}} ->
          Storage.delete_rule_based_segment(name)

        {:error, reason} ->
          Logger.warning("Failed to parse rule-based segment: #{inspect(reason)}")
      end
    end)

    Storage.set_rule_based_segments_change_number(till)
  end

  defp process_rule_based_segments(_), do: :ok
end
