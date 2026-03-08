defmodule Splitio.Impressions.Counter do
  @moduledoc """
  Impression count tracking for OPTIMIZED and NONE modes.

  Tracks raw counts per feature per hour for deduped impressions.
  """

  use GenServer

  @hour_ms 3_600_000

  defstruct counts: %{}

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment count for a feature"
  @spec increment(String.t(), non_neg_integer()) :: :ok
  def increment(feature, timestamp) do
    hour = truncate_to_hour(timestamp)
    GenServer.cast(__MODULE__, {:increment, feature, hour})
  end

  @doc "Pop all counts and reset"
  @spec pop_counts() :: %{{String.t(), non_neg_integer()} => non_neg_integer()}
  def pop_counts do
    GenServer.call(__MODULE__, :pop_counts)
  end

  @doc "Check if there are any counts"
  @spec empty?() :: boolean()
  def empty? do
    GenServer.call(__MODULE__, :empty?)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:increment, feature, hour}, state) do
    key = {feature, hour}
    counts = Map.update(state.counts, key, 1, &(&1 + 1))
    {:noreply, %{state | counts: counts}}
  end

  @impl true
  def handle_call(:pop_counts, _from, state) do
    {:reply, state.counts, %{state | counts: %{}}}
  end

  @impl true
  def handle_call(:empty?, _from, state) do
    {:reply, map_size(state.counts) == 0, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp truncate_to_hour(timestamp_ms) do
    timestamp_ms - rem(timestamp_ms, @hour_ms)
  end
end
