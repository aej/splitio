defmodule Splitio.Localhost.YamlParser do
  @moduledoc """
  YAML file parser for localhost mode.

  Parses YAML format split definitions.
  """

  alias Splitio.Models.{Split, Condition, MatcherGroup, Matcher, Partition}

  @doc """
  Parse a YAML file into split definitions.
  """
  @spec parse_file(String.t()) :: {:ok, [Split.t()]} | {:error, term()}
  def parse_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml_data} when is_list(yaml_data) ->
        splits = parse_yaml_entries(yaml_data)
        {:ok, splits}

      {:ok, _} ->
        {:error, :invalid_yaml_format}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse YAML content string into split definitions.
  """
  @spec parse_string(String.t()) :: {:ok, [Split.t()]} | {:error, term()}
  def parse_string(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, yaml_data} when is_list(yaml_data) ->
        splits = parse_yaml_entries(yaml_data)
        {:ok, splits}

      {:ok, _} ->
        {:error, :invalid_yaml_format}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_yaml_entries(entries) do
    entries
    |> Enum.flat_map(&parse_yaml_entry/1)
    |> merge_split_entries()
  end

  defp parse_yaml_entry(entry) when is_map(entry) do
    Enum.map(entry, fn {name, config} ->
      parse_split_config(name, config)
    end)
  end

  defp parse_yaml_entry(_), do: []

  defp parse_split_config(name, config) when is_map(config) do
    treatment = config["treatment"] || "control"
    keys = normalize_keys(config["keys"])
    cfg = config["config"]

    condition = build_condition(keys, treatment)
    configurations = if cfg, do: %{treatment => cfg}, else: %{}

    %Split{
      name: name,
      default_treatment: treatment,
      change_number: System.system_time(:millisecond),
      killed: false,
      status: :active,
      algo: :murmur,
      traffic_allocation: 100,
      traffic_allocation_seed: :rand.uniform(1_000_000_000),
      seed: :rand.uniform(1_000_000_000),
      conditions: [condition],
      configurations: configurations,
      sets: MapSet.new(),
      impressions_disabled: false,
      prerequisites: []
    }
  end

  defp parse_split_config(name, treatment) when is_binary(treatment) do
    parse_split_config(name, %{"treatment" => treatment})
  end

  defp parse_split_config(_name, _), do: nil

  defp normalize_keys(nil), do: nil
  defp normalize_keys(key) when is_binary(key), do: [key]
  defp normalize_keys(keys) when is_list(keys), do: keys
  defp normalize_keys(_), do: nil

  defp build_condition(nil, treatment) do
    # ALL_KEYS condition
    %Condition{
      condition_type: :rollout,
      matcher_group: %MatcherGroup{
        combiner: :and,
        matchers: [%Matcher{matcher_type: :all_keys}]
      },
      partitions: [%Partition{treatment: treatment, size: 100}],
      label: "default rule"
    }
  end

  defp build_condition(keys, treatment) do
    # Whitelist condition
    %Condition{
      condition_type: :whitelist,
      matcher_group: %MatcherGroup{
        combiner: :and,
        matchers: [%Matcher{matcher_type: :whitelist, whitelist: keys}]
      },
      partitions: [%Partition{treatment: treatment, size: 100}],
      label: "whitelisted"
    }
  end

  # Merge multiple entries for the same split (whitelist + rollout)
  defp merge_split_entries(splits) do
    splits
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, [first | rest]} ->
      # Combine conditions from all entries
      conditions = Enum.flat_map([first | rest], & &1.conditions)
      configurations = Enum.reduce([first | rest], %{}, &Map.merge(&2, &1.configurations))
      %{first | conditions: conditions, configurations: configurations}
    end)
  end
end
