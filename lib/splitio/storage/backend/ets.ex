defmodule Splitio.Storage.Backend.ETS do
  @moduledoc """
  ETS-based storage backend for single-node deployments.

  Provides fast, concurrent reads directly from ETS tables.
  No GenServer bottleneck for reads - direct ETS access.
  """

  @behaviour Splitio.Storage.Backend

  alias Splitio.Models.{Split, Segment, RuleBasedSegment}

  # Table names
  @splits_table :splitio_splits
  @segments_table :splitio_segments
  @large_segments_table :splitio_large_segments
  @rule_based_segments_table :splitio_rule_based_segments
  @metadata_table :splitio_metadata

  # Metadata keys
  @splits_cn_key :splits_change_number
  @rbs_cn_key :rule_based_segments_change_number

  # ============================================================================
  # Splits
  # ============================================================================

  @impl true
  def get_split(name) do
    case :ets.lookup(@splits_table, name) do
      [{^name, split}] -> {:ok, split}
      [] -> :not_found
    end
  end

  @impl true
  def get_splits do
    :ets.tab2list(@splits_table)
    |> Enum.map(fn {_name, split} -> split end)
  end

  @impl true
  def get_split_names do
    :ets.tab2list(@splits_table)
    |> Enum.map(fn {name, _split} -> name end)
  end

  @impl true
  def put_split(%Split{} = split) do
    :ets.insert(@splits_table, {split.name, split})
    :ok
  end

  @impl true
  def delete_split(name) do
    :ets.delete(@splits_table, name)
    :ok
  end

  @impl true
  def get_splits_change_number do
    case :ets.lookup(@metadata_table, @splits_cn_key) do
      [{@splits_cn_key, cn}] -> cn
      [] -> -1
    end
  end

  @impl true
  def set_splits_change_number(cn) do
    :ets.insert(@metadata_table, {@splits_cn_key, cn})
    :ok
  end

  # ============================================================================
  # Flag Sets
  # ============================================================================

  @impl true
  def get_splits_by_flag_set(flag_set) do
    get_splits()
    |> Enum.filter(fn split -> MapSet.member?(split.sets, flag_set) end)
  end

  @impl true
  def get_splits_by_flag_sets(flag_sets) do
    flag_set_set = MapSet.new(flag_sets)

    get_splits()
    |> Enum.filter(fn split ->
      not MapSet.disjoint?(split.sets, flag_set_set)
    end)
  end

  # ============================================================================
  # Segments
  # ============================================================================

  @impl true
  def get_segment(name) do
    case :ets.lookup(@segments_table, name) do
      [{^name, segment}] -> {:ok, segment}
      [] -> :not_found
    end
  end

  @impl true
  def put_segment(%Segment{} = segment) do
    :ets.insert(@segments_table, {segment.name, segment})
    :ok
  end

  @impl true
  def segment_contains?(name, key) do
    case :ets.lookup(@segments_table, name) do
      [{^name, %Segment{keys: keys}}] -> MapSet.member?(keys, key)
      [] -> false
    end
  end

  @impl true
  def get_segment_change_number(name) do
    case :ets.lookup(@segments_table, name) do
      [{^name, %Segment{change_number: cn}}] -> cn
      [] -> -1
    end
  end

  @impl true
  def set_segment_change_number(name, cn) do
    case :ets.lookup(@segments_table, name) do
      [{^name, segment}] ->
        :ets.insert(@segments_table, {name, %{segment | change_number: cn}})
        :ok

      [] ->
        segment = %Segment{name: name, change_number: cn}
        :ets.insert(@segments_table, {name, segment})
        :ok
    end
  end

  @impl true
  def get_segment_names do
    :ets.tab2list(@segments_table)
    |> Enum.map(fn {name, _segment} -> name end)
  end

  @impl true
  def update_segment(name, added, removed, change_number) do
    case :ets.lookup(@segments_table, name) do
      [{^name, segment}] ->
        updated = Segment.update(segment, added, removed, change_number)
        :ets.insert(@segments_table, {name, updated})
        :ok

      [] ->
        segment = %Segment{name: name, keys: MapSet.new(added), change_number: change_number}
        :ets.insert(@segments_table, {name, segment})
        :ok
    end
  end

  # ============================================================================
  # Large Segments
  # ============================================================================

  @impl true
  def large_segment_contains?(name, key) do
    case :ets.lookup(@large_segments_table, name) do
      [{^name, {keys, _cn}}] -> MapSet.member?(keys, key)
      [] -> false
    end
  end

  @impl true
  def put_large_segment_keys(name, keys, change_number) do
    :ets.insert(@large_segments_table, {name, {keys, change_number}})
    :ok
  end

  @impl true
  def get_large_segment_change_number(name) do
    case :ets.lookup(@large_segments_table, name) do
      [{^name, {_keys, cn}}] -> cn
      [] -> -1
    end
  end

  @impl true
  def clear_large_segment(name) do
    :ets.delete(@large_segments_table, name)
    :ok
  end

  # ============================================================================
  # Rule-Based Segments
  # ============================================================================

  @impl true
  def get_rule_based_segment(name) do
    case :ets.lookup(@rule_based_segments_table, name) do
      [{^name, rbs}] -> {:ok, rbs}
      [] -> :not_found
    end
  end

  @impl true
  def put_rule_based_segment(%RuleBasedSegment{} = rbs) do
    :ets.insert(@rule_based_segments_table, {rbs.name, rbs})
    :ok
  end

  @impl true
  def delete_rule_based_segment(name) do
    :ets.delete(@rule_based_segments_table, name)
    :ok
  end

  @impl true
  def get_rule_based_segments_change_number do
    case :ets.lookup(@metadata_table, @rbs_cn_key) do
      [{@rbs_cn_key, cn}] -> cn
      [] -> -1
    end
  end

  @impl true
  def set_rule_based_segments_change_number(cn) do
    :ets.insert(@metadata_table, {@rbs_cn_key, cn})
    :ok
  end
end
