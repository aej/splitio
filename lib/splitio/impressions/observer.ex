defmodule Splitio.Impressions.Observer do
  @moduledoc """
  Impression deduplication using LRU cache.

  Tracks impressions per hour window and prevents sending duplicates.
  Uses ETS for fast concurrent access.
  """

  alias Splitio.Models.Impression
  alias Splitio.Engine.Hash.Murmur3

  @max_cache_size 500_000
  @hour_ms 3_600_000

  @table :splitio_impressions_cache

  @doc """
  Test if impression was seen before and update cache.

  Returns the impression with `previous_time` set if it was seen before.
  """
  @spec test_and_set(Impression.t()) :: Impression.t()
  def test_and_set(%Impression{} = impression) do
    hash = hash_impression(impression)
    current_time = impression.time

    case :ets.lookup(@table, hash) do
      [{^hash, previous_time}] ->
        :ets.insert(@table, {hash, current_time})
        maybe_evict_lru()
        %{impression | previous_time: previous_time}

      [] ->
        :ets.insert(@table, {hash, current_time})
        maybe_evict_lru()
        impression
    end
  end

  @doc """
  Check if an impression should be sent based on deduplication rules.

  In OPTIMIZED mode:
  - First impression ever: send
  - First impression in current hour: send
  - Otherwise: don't send (just count)
  """
  @spec should_send?(Impression.t()) :: boolean()
  def should_send?(%Impression{previous_time: nil}), do: true

  def should_send?(%Impression{previous_time: previous_time, time: current_time}) do
    current_hour = truncate_to_hour(current_time)
    previous_hour = truncate_to_hour(previous_time)
    previous_hour < current_hour
  end

  @doc """
  Get cache size for telemetry.
  """
  @spec cache_size() :: non_neg_integer()
  def cache_size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  # Hash impression for cache key
  # Key: {key}:{feature}:{treatment}:{label}:{change_number}
  defp hash_impression(%Impression{} = imp) do
    data = "#{imp.key}:#{imp.feature}:#{imp.treatment}:#{imp.label}:#{imp.change_number}"
    Murmur3.hash128_lower64(data, 0)
  end

  defp truncate_to_hour(timestamp_ms) do
    timestamp_ms - rem(timestamp_ms, @hour_ms)
  end

  # Evict old entries if cache is too large
  # Simple strategy: delete random entries when over limit
  defp maybe_evict_lru do
    size = cache_size()

    if size > @max_cache_size do
      # Delete approximately 10% of entries
      to_delete = div(size, 10)
      evict_entries(to_delete)
    end
  end

  defp evict_entries(count) when count > 0 do
    # Get first key and delete it
    case :ets.first(@table) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(@table, key)
        evict_entries(count - 1)
    end
  end

  defp evict_entries(_), do: :ok
end
