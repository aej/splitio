defmodule Splitio.Engine.Evaluator do
  @moduledoc """
  Main evaluation engine for feature flags.

  Implements the evaluation algorithm:
  1. Lookup split definition
  2. Check if killed
  3. Check prerequisites
  4. Check traffic allocation
  5. Match conditions
  6. Calculate bucket and select treatment
  """

  alias Splitio.Models.{Split, Condition, MatcherGroup, EvaluationResult, RuleBasedSegment}
  alias Splitio.Engine.{Splitter, Matchers}
  alias Splitio.Storage
  alias Splitio.Key

  require Logger

  @max_recursion_depth 10

  # Labels
  @label_not_found "definition not found"
  @label_killed "killed"
  @label_not_in_split "not in split"
  @label_default_rule "default rule"
  @label_prerequisites_not_met "prerequisites not met"
  # Reserved for future use
  # @label_unsupported "targeting rule type unsupported by sdk"

  @type attributes :: map()

  @doc """
  Evaluate a feature flag for the given key.

  Returns an EvaluationResult with treatment, label, and optional config.
  """
  @spec evaluate(String.t() | Key.t(), String.t(), attributes()) :: EvaluationResult.t()
  def evaluate(key, split_name, attributes \\ %{}) do
    key = Key.new(key)
    do_evaluate(key, split_name, attributes, 0)
  end

  defp do_evaluate(key, split_name, attributes, depth) do
    case Storage.get_split(split_name) do
      :not_found ->
        {treatment, config} = Splitio.FallbackTreatment.resolve(split_name, "control")

        %EvaluationResult{
          treatment: treatment,
          label: @label_not_found,
          config: config,
          change_number: 0
        }

      {:ok, split} ->
        evaluate_split(split, key, attributes, depth)
    end
  end

  defp evaluate_split(%Split{killed: true} = split, _key, _attributes, _depth) do
    %EvaluationResult{
      treatment: split.default_treatment,
      label: @label_killed,
      config: Split.get_config(split, split.default_treatment),
      change_number: split.change_number,
      impressions_disabled: split.impressions_disabled
    }
  end

  defp evaluate_split(%Split{} = split, key, attributes, depth) do
    # Check prerequisites first
    if check_prerequisites(split.prerequisites, key, attributes, depth) do
      evaluate_conditions(split, key, attributes, depth)
    else
      %EvaluationResult{
        treatment: split.default_treatment,
        label: @label_prerequisites_not_met,
        config: Split.get_config(split, split.default_treatment),
        change_number: split.change_number,
        impressions_disabled: split.impressions_disabled
      }
    end
  end

  defp check_prerequisites([], _key, _attributes, _depth), do: true

  defp check_prerequisites(prerequisites, key, attributes, depth) do
    Enum.all?(prerequisites, fn prereq ->
      result = do_evaluate(key, prereq.feature_flag, attributes, depth + 1)
      result.treatment in prereq.treatments
    end)
  end

  defp evaluate_conditions(%Split{} = split, key, attributes, depth) do
    bucketing_key = Key.bucketing_key(key)
    matching_key = Key.matching_key(key)

    context = %{
      key: matching_key,
      bucketing_key: bucketing_key,
      attributes: attributes,
      evaluator: __MODULE__,
      depth: depth
    }

    # Track if we've seen a rollout condition (for traffic allocation)
    {result, _in_rollout} =
      Enum.reduce_while(split.conditions, {nil, false}, fn condition, {_result, in_rollout} ->
        # Traffic allocation check - only on first ROLLOUT condition
        if not in_rollout and condition.condition_type == :rollout do
          if not in_traffic_allocation?(bucketing_key, split) do
            {:halt,
             {%EvaluationResult{
                treatment: split.default_treatment,
                label: @label_not_in_split,
                config: Split.get_config(split, split.default_treatment),
                change_number: split.change_number,
                impressions_disabled: split.impressions_disabled
              }, true}}
          else
            try_match_condition(condition, split, context, true)
          end
        else
          try_match_condition(condition, split, context, in_rollout)
        end
      end)

    case result do
      nil ->
        # No condition matched - return default
        %EvaluationResult{
          treatment: split.default_treatment,
          label: @label_default_rule,
          config: Split.get_config(split, split.default_treatment),
          change_number: split.change_number,
          impressions_disabled: split.impressions_disabled
        }

      %EvaluationResult{} = res ->
        res
    end
  end

  defp try_match_condition(condition, split, context, in_rollout) do
    if matches_condition?(condition, context) do
      treatment = get_treatment_for_condition(condition, context.bucketing_key, split)

      {:halt,
       {%EvaluationResult{
          treatment: treatment,
          label: condition.label,
          config: Split.get_config(split, treatment),
          change_number: split.change_number,
          impressions_disabled: split.impressions_disabled
        }, in_rollout}}
    else
      {:cont, {nil, in_rollout or condition.condition_type == :rollout}}
    end
  end

  defp in_traffic_allocation?(_bucketing_key, %Split{traffic_allocation: 100}), do: true

  defp in_traffic_allocation?(bucketing_key, split) do
    bucket =
      Splitter.calculate_bucket(bucketing_key, split.traffic_allocation_seed || 0, split.algo)

    bucket <= split.traffic_allocation
  end

  defp matches_condition?(%Condition{matcher_group: matcher_group}, context) do
    matches_matcher_group?(matcher_group, context)
  end

  defp matches_matcher_group?(%MatcherGroup{matchers: matchers}, context) do
    # AND combiner - all matchers must match
    Enum.all?(matchers, fn matcher ->
      Matchers.evaluate(matcher, context)
    end)
  end

  defp get_treatment_for_condition(condition, bucketing_key, split) do
    Splitter.get_treatment(
      bucketing_key,
      split.seed || 0,
      condition.partitions,
      split.algo
    )
  end

  # ============================================================================
  # Callbacks for Matchers module
  # ============================================================================

  @doc """
  Evaluate a dependency (for IN_SPLIT_TREATMENT matcher).
  """
  @spec evaluate_dependency(String.t(), map()) :: EvaluationResult.t()
  def evaluate_dependency(split_name, context) do
    key = Key.new(context.key, context.bucketing_key)
    do_evaluate(key, split_name, context.attributes, context.depth + 1)
  end

  @doc """
  Evaluate a rule-based segment membership (for IN_RULE_BASED_SEGMENT matcher).
  """
  @spec evaluate_rule_based_segment(String.t(), map()) :: boolean()
  def evaluate_rule_based_segment(segment_name, context) do
    depth = Map.get(context, :depth, 0)

    if depth >= @max_recursion_depth do
      Logger.error("Rule-based segment recursion depth exceeded for #{segment_name}")
      false
    else
      do_evaluate_rule_based_segment(segment_name, context, depth)
    end
  end

  defp do_evaluate_rule_based_segment(segment_name, context, depth) do
    case Storage.get_rule_based_segment(segment_name) do
      :not_found ->
        false

      {:ok, %RuleBasedSegment{} = rbs} ->
        evaluate_rbs(rbs, context, depth)
    end
  end

  defp evaluate_rbs(%RuleBasedSegment{excluded: excluded} = rbs, context, depth) do
    key = context.key

    # Check explicit key exclusions
    if MapSet.member?(excluded.keys, key) do
      false
    else
      # Check segment-based exclusions
      excluded_by_segment =
        Enum.any?(excluded.segments, fn excluded_seg ->
          case excluded_seg.type do
            :standard ->
              Storage.segment_contains?(excluded_seg.name, key)

            :rule_based ->
              new_context = Map.put(context, :depth, depth + 1)
              evaluate_rule_based_segment(excluded_seg.name, new_context)

            :large ->
              Storage.large_segment_contains?(excluded_seg.name, key)
          end
        end)

      if excluded_by_segment do
        false
      else
        # Evaluate conditions (first match wins)
        rbs_context = Map.put(context, :depth, depth + 1)
        Enum.any?(rbs.conditions, &matches_condition?(&1, rbs_context))
      end
    end
  end
end
