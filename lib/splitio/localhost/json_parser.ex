defmodule Splitio.Localhost.JsonParser do
  @moduledoc """
  JSON file parser for localhost mode.

  Parses full Split API JSON format.
  """

  alias Splitio.Models.Split

  @doc """
  Parse a JSON file into split definitions.
  """
  @spec parse_file(String.t()) :: {:ok, [Split.t()]} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_string(content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse JSON content string into split definitions.
  """
  @spec parse_string(String.t()) :: {:ok, [Split.t()]} | {:error, term()}
  def parse_string(content) do
    case Jason.decode(content) do
      {:ok, json} ->
        splits = parse_json(json)
        {:ok, splits}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_json(%{"ff" => %{"d" => splits_data}}) when is_list(splits_data) do
    parse_splits(splits_data)
  end

  defp parse_json(%{"splits" => splits_data}) when is_list(splits_data) do
    parse_splits(splits_data)
  end

  defp parse_json(_), do: []

  defp parse_splits(splits_data) do
    splits_data
    |> Enum.map(&parse_and_sanitize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_and_sanitize(split_json) do
    case Split.from_json(split_json) do
      {:ok, split} ->
        sanitize_split(split)

      {:error, _} ->
        nil
    end
  end

  # Sanitize localhost split values
  defp sanitize_split(%Split{} = split) do
    %{
      split
      | traffic_allocation: clamp(split.traffic_allocation || 100, 0, 100),
        traffic_allocation_seed: ensure_seed(split.traffic_allocation_seed),
        seed: ensure_seed(split.seed),
        status: split.status || :active,
        default_treatment: split.default_treatment || "control",
        algo: :murmur,
        conditions: ensure_conditions(split.conditions)
    }
  end

  defp clamp(value, min, max), do: max(min, min(value, max))

  defp ensure_seed(0), do: :rand.uniform(1_000_000_000)
  defp ensure_seed(nil), do: :rand.uniform(1_000_000_000)
  defp ensure_seed(seed), do: seed

  defp ensure_conditions([]), do: [default_rollout_condition()]
  defp ensure_conditions(conditions), do: conditions

  defp default_rollout_condition do
    alias Splitio.Models.{Condition, MatcherGroup, Matcher, Partition}

    %Condition{
      condition_type: :rollout,
      matcher_group: %MatcherGroup{
        combiner: :and,
        matchers: [%Matcher{matcher_type: :all_keys}]
      },
      partitions: [%Partition{treatment: "control", size: 100}],
      label: "default rule"
    }
  end
end
