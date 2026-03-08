defmodule Splitio.Engine.Matchers do
  @moduledoc """
  Matcher evaluation logic.

  Implements all matcher types for condition evaluation.
  Each matcher returns true/false based on the input value.
  """

  alias Splitio.Models.Matcher
  alias Splitio.Engine.Matchers.Semver
  alias Splitio.Storage

  require Logger

  @type eval_context :: %{
          key: String.t(),
          bucketing_key: String.t(),
          attributes: map(),
          evaluator: module()
        }

  @doc """
  Evaluate a matcher against the given context.

  Returns true if the matcher matches, false otherwise.
  Handles negation automatically.
  """
  @spec evaluate(Matcher.t(), eval_context()) :: boolean()
  def evaluate(%Matcher{negate: negate} = matcher, context) do
    result = do_evaluate(matcher, context)

    if negate do
      not result
    else
      result
    end
  end

  # ALL_KEYS - matches everything
  defp do_evaluate(%Matcher{matcher_type: :all_keys}, _context), do: true

  # IN_SEGMENT - key in segment
  defp do_evaluate(%Matcher{matcher_type: :in_segment, segment_name: name}, context) do
    Storage.segment_contains?(name, context.key)
  end

  # IN_LARGE_SEGMENT - key in large segment
  defp do_evaluate(%Matcher{matcher_type: :in_large_segment, segment_name: name}, context) do
    Storage.large_segment_contains?(name, context.key)
  end

  # IN_RULE_BASED_SEGMENT - key matches rule-based segment
  defp do_evaluate(%Matcher{matcher_type: :in_rule_based_segment, segment_name: name}, context) do
    context.evaluator.evaluate_rule_based_segment(name, context)
  end

  # WHITELIST - key in explicit list
  defp do_evaluate(%Matcher{matcher_type: :whitelist, whitelist: whitelist}, context) do
    context.key in whitelist
  end

  # EQUAL_TO_BOOLEAN
  defp do_evaluate(%Matcher{matcher_type: :equal_to_boolean, value: expected} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} -> coerce_boolean(value) == expected
      _ -> false
    end
  end

  # EQUAL_TO (numeric)
  defp do_evaluate(%Matcher{matcher_type: :equal_to, value: expected, data_type: dt} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} ->
        with {:ok, val} <- coerce_numeric(value, dt),
             {:ok, exp} <- coerce_numeric(expected, dt) do
          if dt == :datetime do
            truncate_to_day(val) == truncate_to_day(exp)
          else
            val == exp
          end
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # GREATER_THAN_OR_EQUAL_TO (numeric)
  defp do_evaluate(
         %Matcher{matcher_type: :greater_than_or_equal_to, value: expected, data_type: dt} = m,
         context
       ) do
    case get_matching_value(m, context) do
      {:ok, value} ->
        with {:ok, val} <- coerce_numeric(value, dt),
             {:ok, exp} <- coerce_numeric(expected, dt) do
          val = maybe_truncate_seconds(val, dt)
          exp = maybe_truncate_seconds(exp, dt)
          val >= exp
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # LESS_THAN_OR_EQUAL_TO (numeric)
  defp do_evaluate(
         %Matcher{matcher_type: :less_than_or_equal_to, value: expected, data_type: dt} = m,
         context
       ) do
    case get_matching_value(m, context) do
      {:ok, value} ->
        with {:ok, val} <- coerce_numeric(value, dt),
             {:ok, exp} <- coerce_numeric(expected, dt) do
          val = maybe_truncate_seconds(val, dt)
          exp = maybe_truncate_seconds(exp, dt)
          val <= exp
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # BETWEEN (numeric)
  defp do_evaluate(
         %Matcher{
           matcher_type: :between,
           start_value: start_val,
           end_value: end_val,
           data_type: dt
         } = m,
         context
       ) do
    case get_matching_value(m, context) do
      {:ok, value} ->
        with {:ok, val} <- coerce_numeric(value, dt),
             {:ok, sv} <- coerce_numeric(start_val, dt),
             {:ok, ev} <- coerce_numeric(end_val, dt) do
          val = maybe_truncate_seconds(val, dt)
          sv = maybe_truncate_seconds(sv, dt)
          ev = maybe_truncate_seconds(ev, dt)
          val >= sv and val <= ev
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  # EQUAL_TO_SET
  defp do_evaluate(%Matcher{matcher_type: :equal_to_set, whitelist: whitelist} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_list(value) ->
        MapSet.new(value) == MapSet.new(whitelist)

      _ ->
        false
    end
  end

  # CONTAINS_ANY_OF_SET
  defp do_evaluate(
         %Matcher{matcher_type: :contains_any_of_set, whitelist: whitelist} = m,
         context
       ) do
    case get_matching_value(m, context) do
      {:ok, value} when is_list(value) ->
        value_set = MapSet.new(value)
        whitelist_set = MapSet.new(whitelist)
        not MapSet.disjoint?(value_set, whitelist_set)

      _ ->
        false
    end
  end

  # CONTAINS_ALL_OF_SET
  defp do_evaluate(
         %Matcher{matcher_type: :contains_all_of_set, whitelist: whitelist} = m,
         context
       ) do
    case get_matching_value(m, context) do
      {:ok, value} when is_list(value) ->
        value_set = MapSet.new(value)
        whitelist_set = MapSet.new(whitelist)
        MapSet.subset?(whitelist_set, value_set)

      _ ->
        false
    end
  end

  # PART_OF_SET
  defp do_evaluate(%Matcher{matcher_type: :part_of_set, whitelist: whitelist} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_list(value) ->
        value_set = MapSet.new(value)
        whitelist_set = MapSet.new(whitelist)
        MapSet.subset?(value_set, whitelist_set)

      _ ->
        false
    end
  end

  # STARTS_WITH
  defp do_evaluate(%Matcher{matcher_type: :starts_with, whitelist: whitelist} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_binary(value) ->
        Enum.any?(whitelist, &String.starts_with?(value, &1))

      _ ->
        false
    end
  end

  # ENDS_WITH
  defp do_evaluate(%Matcher{matcher_type: :ends_with, whitelist: whitelist} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_binary(value) ->
        Enum.any?(whitelist, &String.ends_with?(value, &1))

      _ ->
        false
    end
  end

  # CONTAINS_STRING
  defp do_evaluate(%Matcher{matcher_type: :contains_string, whitelist: whitelist} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_binary(value) ->
        Enum.any?(whitelist, &String.contains?(value, &1))

      _ ->
        false
    end
  end

  # MATCHES_STRING (regex)
  defp do_evaluate(%Matcher{matcher_type: :matches_string, value: pattern} = m, context) do
    case get_matching_value(m, context) do
      {:ok, value} when is_binary(value) and is_binary(pattern) ->
        case Regex.compile(pattern) do
          {:ok, regex} -> Regex.match?(regex, value)
          _ -> false
        end

      _ ->
        false
    end
  end

  # EQUAL_TO_SEMVER
  defp do_evaluate(%Matcher{matcher_type: :equal_to_semver, value: expected} = m, context) do
    with {:ok, value} <- get_matching_value(m, context),
         {:ok, v_parsed} <- Semver.parse(value),
         {:ok, e_parsed} <- Semver.parse(expected) do
      Semver.equal?(v_parsed, e_parsed)
    else
      _ -> false
    end
  end

  # GREATER_THAN_OR_EQUAL_TO_SEMVER
  defp do_evaluate(
         %Matcher{matcher_type: :greater_than_or_equal_to_semver, value: expected} = m,
         context
       ) do
    with {:ok, value} <- get_matching_value(m, context),
         {:ok, v_parsed} <- Semver.parse(value),
         {:ok, e_parsed} <- Semver.parse(expected) do
      Semver.gte?(v_parsed, e_parsed)
    else
      _ -> false
    end
  end

  # LESS_THAN_OR_EQUAL_TO_SEMVER
  defp do_evaluate(
         %Matcher{matcher_type: :less_than_or_equal_to_semver, value: expected} = m,
         context
       ) do
    with {:ok, value} <- get_matching_value(m, context),
         {:ok, v_parsed} <- Semver.parse(value),
         {:ok, e_parsed} <- Semver.parse(expected) do
      Semver.lte?(v_parsed, e_parsed)
    else
      _ -> false
    end
  end

  # BETWEEN_SEMVER
  defp do_evaluate(
         %Matcher{matcher_type: :between_semver, start_value: start_v, end_value: end_v} = m,
         context
       ) do
    with {:ok, value} <- get_matching_value(m, context),
         {:ok, v_parsed} <- Semver.parse(value),
         {:ok, s_parsed} <- Semver.parse(start_v),
         {:ok, e_parsed} <- Semver.parse(end_v) do
      Semver.between?(v_parsed, s_parsed, e_parsed)
    else
      _ -> false
    end
  end

  # IN_LIST_SEMVER
  defp do_evaluate(%Matcher{matcher_type: :in_list_semver, whitelist: whitelist} = m, context) do
    with {:ok, value} <- get_matching_value(m, context),
         {:ok, v_parsed} <- Semver.parse(value) do
      Enum.any?(whitelist, fn target ->
        case Semver.parse(target) do
          {:ok, t_parsed} -> Semver.equal?(v_parsed, t_parsed)
          _ -> false
        end
      end)
    else
      _ -> false
    end
  end

  # IN_SPLIT_TREATMENT - dependency matcher
  defp do_evaluate(
         %Matcher{
           matcher_type: :in_split_treatment,
           dependency_split: split_name,
           dependency_treatments: treatments
         },
         context
       ) do
    result = context.evaluator.evaluate_dependency(split_name, context)
    result.treatment in treatments
  end

  # Unknown matcher type (catch-all)
  defp do_evaluate(%Matcher{matcher_type: type}, _context) do
    Logger.warning("Unsupported matcher type: #{inspect(type)}")
    false
  end

  # Helper functions

  defp get_matching_value(%Matcher{key_selector: key_selector}, context) do
    case key_selector.attribute do
      nil -> {:ok, context.key}
      attr -> get_attribute(context.attributes, attr)
    end
  end

  defp get_attribute(attributes, attr) when is_map(attributes) do
    case Map.fetch(attributes, attr) do
      {:ok, value} -> {:ok, value}
      :error -> :missing
    end
  end

  defp get_attribute(_, _), do: :missing

  defp coerce_boolean(true), do: true
  defp coerce_boolean(false), do: false
  defp coerce_boolean("true"), do: true
  defp coerce_boolean("false"), do: false
  defp coerce_boolean(s) when is_binary(s), do: String.downcase(s) == "true"
  defp coerce_boolean(_), do: nil

  defp coerce_numeric(value, _) when is_integer(value), do: {:ok, value}
  defp coerce_numeric(value, _) when is_float(value), do: {:ok, trunc(value)}
  defp coerce_numeric(_, _), do: :error

  defp truncate_to_day(timestamp_ms) do
    day_ms = 86_400_000
    div(timestamp_ms, day_ms) * day_ms
  end

  defp maybe_truncate_seconds(timestamp_ms, :datetime) do
    minute_ms = 60_000
    div(timestamp_ms, minute_ms) * minute_ms
  end

  defp maybe_truncate_seconds(value, _), do: value
end
