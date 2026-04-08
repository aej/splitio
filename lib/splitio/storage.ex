defmodule Splitio.Storage do
  @moduledoc """
  Storage facade - routes to configured backend.

  Provides a unified interface for all storage operations,
  delegating to the configured backend implementation.
  """

  alias Splitio.Models.{Split, Segment, RuleBasedSegment}

  @type split_name :: String.t()
  @type segment_name :: String.t()
  @type change_number :: integer()

  # ============================================================================
  # Splits
  # ============================================================================

  @spec get_split(split_name()) :: {:ok, Split.t()} | :not_found
  def get_split(name), do: backend().get_split(name)

  @spec get_splits() :: [Split.t()]
  def get_splits, do: backend().get_splits()

  @spec get_split_names() :: [split_name()]
  def get_split_names, do: backend().get_split_names()

  @spec put_split(Split.t()) :: :ok
  def put_split(split), do: backend().put_split(split)

  @spec delete_split(split_name()) :: :ok
  def delete_split(name), do: backend().delete_split(name)

  @spec get_splits_change_number() :: change_number()
  def get_splits_change_number, do: backend().get_splits_change_number()

  @spec set_splits_change_number(change_number()) :: :ok
  def set_splits_change_number(cn), do: backend().set_splits_change_number(cn)

  # ============================================================================
  # Flag Sets
  # ============================================================================

  @spec get_splits_by_flag_set(String.t()) :: [Split.t()]
  def get_splits_by_flag_set(flag_set), do: backend().get_splits_by_flag_set(flag_set)

  @spec get_splits_by_flag_sets([String.t()]) :: [Split.t()]
  def get_splits_by_flag_sets(flag_sets), do: backend().get_splits_by_flag_sets(flag_sets)

  # ============================================================================
  # Segments
  # ============================================================================

  @spec get_segment(segment_name()) :: {:ok, Segment.t()} | :not_found
  def get_segment(name), do: backend().get_segment(name)

  @spec put_segment(Segment.t()) :: :ok
  def put_segment(segment), do: backend().put_segment(segment)

  @spec delete_segment(segment_name()) :: :ok
  def delete_segment(name), do: backend().delete_segment(name)

  @spec segment_contains?(segment_name(), String.t()) :: boolean()
  def segment_contains?(name, key), do: backend().segment_contains?(name, key)

  @spec get_segment_change_number(segment_name()) :: change_number()
  def get_segment_change_number(name), do: backend().get_segment_change_number(name)

  @spec set_segment_change_number(segment_name(), change_number()) :: :ok
  def set_segment_change_number(name, cn), do: backend().set_segment_change_number(name, cn)

  @spec get_segment_names() :: [segment_name()]
  def get_segment_names, do: backend().get_segment_names()

  @spec update_segment(segment_name(), [String.t()], [String.t()], change_number()) :: :ok
  def update_segment(name, added, removed, cn),
    do: backend().update_segment(name, added, removed, cn)

  # ============================================================================
  # Large Segments
  # ============================================================================

  @spec large_segment_contains?(segment_name(), String.t()) :: boolean()
  def large_segment_contains?(name, key), do: backend().large_segment_contains?(name, key)

  @spec put_large_segment_keys(segment_name(), MapSet.t(), change_number()) :: :ok
  def put_large_segment_keys(name, keys, cn), do: backend().put_large_segment_keys(name, keys, cn)

  @spec get_large_segment_change_number(segment_name()) :: change_number()
  def get_large_segment_change_number(name), do: backend().get_large_segment_change_number(name)

  @spec clear_large_segment(segment_name()) :: :ok
  def clear_large_segment(name), do: backend().clear_large_segment(name)

  # ============================================================================
  # Rule-Based Segments
  # ============================================================================

  @spec get_rule_based_segment(segment_name()) :: {:ok, RuleBasedSegment.t()} | :not_found
  def get_rule_based_segment(name), do: backend().get_rule_based_segment(name)

  @spec put_rule_based_segment(RuleBasedSegment.t()) :: :ok
  def put_rule_based_segment(rbs), do: backend().put_rule_based_segment(rbs)

  @spec delete_rule_based_segment(segment_name()) :: :ok
  def delete_rule_based_segment(name), do: backend().delete_rule_based_segment(name)

  @spec get_rule_based_segments_change_number() :: change_number()
  def get_rule_based_segments_change_number, do: backend().get_rule_based_segments_change_number()

  @spec set_rule_based_segments_change_number(change_number()) :: :ok
  def set_rule_based_segments_change_number(cn),
    do: backend().set_rule_based_segments_change_number(cn)

  # ============================================================================
  # Private
  # ============================================================================

  defp backend do
    Application.get_env(:splitio, :storage_backend, Splitio.Storage.Backend.ETS)
  end
end
