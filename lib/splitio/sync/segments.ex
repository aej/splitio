defmodule Splitio.Sync.Segments do
  @moduledoc """
  Segment synchronization from SDK API.

  Handles incremental segment updates.
  """

  alias Splitio.Api.SDK
  alias Splitio.Config
  alias Splitio.Storage

  require Logger

  @doc """
  Synchronize a single segment.
  """
  @spec sync_segment(Config.t(), String.t()) :: :ok | {:error, term()}
  def sync_segment(%Config{} = config, segment_name) do
    since = Storage.get_segment_change_number(segment_name)
    sync_segment_from(config, segment_name, since)
  end

  @doc """
  Synchronize multiple segments in parallel.
  """
  @spec sync_segments(Config.t(), [String.t()]) :: :ok
  def sync_segments(%Config{} = config, segment_names) do
    segment_names
    |> Task.async_stream(
      fn name -> sync_segment(config, name) end,
      max_concurrency: 10,
      timeout: 60_000
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("Segment sync failed: #{inspect(reason)}")
      {:exit, reason} -> Logger.error("Segment sync crashed: #{inspect(reason)}")
    end)

    :ok
  end

  @doc """
  Force sync segment to a specific change number (CDN bypass).
  """
  @spec sync_segment_to(Config.t(), String.t(), integer()) :: :ok | {:error, term()}
  def sync_segment_to(%Config{} = config, segment_name, till) do
    since = Storage.get_segment_change_number(segment_name)
    sync_segment_with_till(config, segment_name, since, till)
  end

  defp sync_segment_from(config, segment_name, since) do
    case SDK.fetch_segment_changes(config, segment_name, since: since) do
      {:ok, response} ->
        process_segment_response(segment_name, response)
        till = response["till"] || -1

        # Continue fetching if more changes exist
        if since < till do
          sync_segment_from(config, segment_name, till)
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("Failed to fetch segment #{segment_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_segment_with_till(config, segment_name, since, target_till) do
    case SDK.fetch_segment_changes(config, segment_name, since: since, till: target_till) do
      {:ok, response} ->
        process_segment_response(segment_name, response)
        till = response["till"] || -1

        # Continue if still not at target
        if till < target_till do
          sync_segment_with_till(config, segment_name, till, target_till)
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("Failed to fetch segment #{segment_name} (CDN bypass): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_segment_response(segment_name, response) do
    added = response["added"] || []
    removed = response["removed"] || []
    till = response["till"] || -1

    Storage.update_segment(segment_name, added, removed, till)
  end
end
