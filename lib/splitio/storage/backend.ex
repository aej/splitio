defmodule Splitio.Storage.Backend do
  @moduledoc """
  Storage backend behaviour.

  Defines the interface for storage backends (ETS, Redis, etc.).
  All storage operations go through this behaviour, allowing
  different implementations for different deployment scenarios.
  """

  alias Splitio.Models.{Split, Segment, RuleBasedSegment}

  @type split_name :: String.t()
  @type segment_name :: String.t()
  @type change_number :: integer()

  # Splits
  @callback get_split(split_name()) :: {:ok, Split.t()} | :not_found
  @callback get_splits() :: [Split.t()]
  @callback get_split_names() :: [split_name()]
  @callback put_split(Split.t()) :: :ok
  @callback delete_split(split_name()) :: :ok
  @callback get_splits_change_number() :: change_number()
  @callback set_splits_change_number(change_number()) :: :ok

  # Flag sets
  @callback get_splits_by_flag_set(String.t()) :: [Split.t()]
  @callback get_splits_by_flag_sets([String.t()]) :: [Split.t()]

  # Segments
  @callback get_segment(segment_name()) :: {:ok, Segment.t()} | :not_found
  @callback put_segment(Segment.t()) :: :ok
  @callback delete_segment(segment_name()) :: :ok
  @callback segment_contains?(segment_name(), key :: String.t()) :: boolean()
  @callback get_segment_change_number(segment_name()) :: change_number()
  @callback set_segment_change_number(segment_name(), change_number()) :: :ok
  @callback get_segment_names() :: [segment_name()]
  @callback update_segment(
              segment_name(),
              added :: [String.t()],
              removed :: [String.t()],
              change_number()
            ) :: :ok

  # Large Segments
  @callback large_segment_contains?(segment_name(), key :: String.t()) :: boolean()
  @callback put_large_segment_keys(segment_name(), keys :: MapSet.t(), change_number()) :: :ok
  @callback get_large_segment_change_number(segment_name()) :: change_number()
  @callback clear_large_segment(segment_name()) :: :ok

  # Rule-Based Segments
  @callback get_rule_based_segment(segment_name()) :: {:ok, RuleBasedSegment.t()} | :not_found
  @callback put_rule_based_segment(RuleBasedSegment.t()) :: :ok
  @callback delete_rule_based_segment(segment_name()) :: :ok
  @callback get_rule_based_segments_change_number() :: change_number()
  @callback set_rule_based_segments_change_number(change_number()) :: :ok
end
