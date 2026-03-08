defmodule Splitio.Models.Matcher do
  @moduledoc "Individual matching rule"

  alias Splitio.Models.KeySelector

  @type matcher_type ::
          :all_keys
          | :in_segment
          | :whitelist
          | :equal_to
          | :greater_than_or_equal_to
          | :less_than_or_equal_to
          | :between
          | :equal_to_set
          | :part_of_set
          | :contains_all_of_set
          | :contains_any_of_set
          | :starts_with
          | :ends_with
          | :contains_string
          | :matches_string
          | :equal_to_boolean
          | :in_split_treatment
          | :equal_to_semver
          | :greater_than_or_equal_to_semver
          | :less_than_or_equal_to_semver
          | :between_semver
          | :in_list_semver
          | :in_large_segment
          | :in_rule_based_segment
          | :unknown

  @type data_type :: :number | :datetime

  @type t :: %__MODULE__{
          matcher_type: matcher_type(),
          negate: boolean(),
          key_selector: KeySelector.t(),
          segment_name: String.t() | nil,
          whitelist: [String.t()] | nil,
          value: number() | String.t() | boolean() | nil,
          data_type: data_type() | nil,
          start_value: number() | String.t() | nil,
          end_value: number() | String.t() | nil,
          dependency_split: String.t() | nil,
          dependency_treatments: [String.t()] | nil
        }

  @enforce_keys [:matcher_type]
  defstruct [
    :matcher_type,
    :segment_name,
    :whitelist,
    :value,
    :data_type,
    :start_value,
    :end_value,
    :dependency_split,
    :dependency_treatments,
    key_selector: %KeySelector{},
    negate: false
  ]

  @matcher_type_map %{
    "ALL_KEYS" => :all_keys,
    "IN_SEGMENT" => :in_segment,
    "WHITELIST" => :whitelist,
    "EQUAL_TO" => :equal_to,
    "GREATER_THAN_OR_EQUAL_TO" => :greater_than_or_equal_to,
    "LESS_THAN_OR_EQUAL_TO" => :less_than_or_equal_to,
    "BETWEEN" => :between,
    "EQUAL_TO_SET" => :equal_to_set,
    "PART_OF_SET" => :part_of_set,
    "CONTAINS_ALL_OF_SET" => :contains_all_of_set,
    "CONTAINS_ANY_OF_SET" => :contains_any_of_set,
    "STARTS_WITH" => :starts_with,
    "ENDS_WITH" => :ends_with,
    "CONTAINS_STRING" => :contains_string,
    "MATCHES_STRING" => :matches_string,
    "EQUAL_TO_BOOLEAN" => :equal_to_boolean,
    "IN_SPLIT_TREATMENT" => :in_split_treatment,
    "EQUAL_TO_SEMVER" => :equal_to_semver,
    "GREATER_THAN_OR_EQUAL_TO_SEMVER" => :greater_than_or_equal_to_semver,
    "LESS_THAN_OR_EQUAL_TO_SEMVER" => :less_than_or_equal_to_semver,
    "BETWEEN_SEMVER" => :between_semver,
    "IN_LIST_SEMVER" => :in_list_semver,
    "IN_LARGE_SEGMENT" => :in_large_segment,
    "IN_RULE_BASED_SEGMENT" => :in_rule_based_segment
  }

  @spec from_json(map()) :: t()
  def from_json(json) do
    matcher_type = Map.get(@matcher_type_map, json["matcherType"], :unknown)
    key_selector = KeySelector.from_json(json["keySelector"])

    base = %__MODULE__{
      matcher_type: matcher_type,
      negate: json["negate"] || false,
      key_selector: key_selector
    }

    parse_matcher_data(base, matcher_type, json)
  end

  # Segment matchers
  defp parse_matcher_data(base, :in_segment, json) do
    %{base | segment_name: get_in(json, ["userDefinedSegmentMatcherData", "segmentName"])}
  end

  defp parse_matcher_data(base, :in_large_segment, json) do
    %{
      base
      | segment_name: get_in(json, ["userDefinedLargeSegmentMatcherData", "largeSegmentName"])
    }
  end

  defp parse_matcher_data(base, :in_rule_based_segment, json) do
    %{base | segment_name: get_in(json, ["userDefinedSegmentMatcherData", "segmentName"])}
  end

  # Whitelist-based matchers
  defp parse_matcher_data(base, type, json)
       when type in [
              :whitelist,
              :starts_with,
              :ends_with,
              :contains_string,
              :equal_to_set,
              :part_of_set,
              :contains_all_of_set,
              :contains_any_of_set,
              :in_list_semver
            ] do
    %{base | whitelist: get_in(json, ["whitelistMatcherData", "whitelist"]) || []}
  end

  # Numeric unary matchers
  defp parse_matcher_data(base, type, json)
       when type in [:equal_to, :greater_than_or_equal_to, :less_than_or_equal_to] do
    data = json["unaryNumericMatcherData"] || %{}

    %{
      base
      | value: data["value"],
        data_type: parse_data_type(data["dataType"])
    }
  end

  # Numeric between matcher
  defp parse_matcher_data(base, :between, json) do
    data = json["betweenMatcherData"] || %{}

    %{
      base
      | start_value: data["start"],
        end_value: data["end"],
        data_type: parse_data_type(data["dataType"])
    }
  end

  # String-based matchers (semver and regex)
  defp parse_matcher_data(base, type, json)
       when type in [
              :equal_to_semver,
              :greater_than_or_equal_to_semver,
              :less_than_or_equal_to_semver,
              :matches_string
            ] do
    %{base | value: get_in(json, ["stringMatcherData", "string"])}
  end

  # Semver between
  defp parse_matcher_data(base, :between_semver, json) do
    data = json["betweenStringMatcherData"] || %{}
    %{base | start_value: data["start"], end_value: data["end"]}
  end

  # Boolean matcher
  defp parse_matcher_data(base, :equal_to_boolean, json) do
    %{base | value: get_in(json, ["booleanMatcherData", "value"])}
  end

  # Dependency matcher
  defp parse_matcher_data(base, :in_split_treatment, json) do
    data = json["dependencyMatcherData"] || %{}

    %{
      base
      | dependency_split: data["split"],
        dependency_treatments: data["treatments"] || []
    }
  end

  defp parse_matcher_data(base, _type, _json), do: base

  defp parse_data_type("NUMBER"), do: :number
  defp parse_data_type("DATETIME"), do: :datetime
  defp parse_data_type(_), do: :number
end
