defmodule Splitio.Models.Condition do
  @moduledoc "Targeting condition within a split"

  alias Splitio.Models.{MatcherGroup, Partition}

  @type condition_type :: :rollout | :whitelist

  @type t :: %__MODULE__{
          condition_type: condition_type(),
          matcher_group: MatcherGroup.t(),
          partitions: [Partition.t()],
          label: String.t()
        }

  @enforce_keys [:condition_type, :matcher_group, :partitions, :label]
  defstruct [:condition_type, :matcher_group, :partitions, :label]

  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      condition_type: parse_condition_type(json["conditionType"]),
      matcher_group: MatcherGroup.from_json(json["matcherGroup"] || %{}),
      partitions: Enum.map(json["partitions"] || [], &Partition.from_json/1),
      label: json["label"] || "default rule"
    }
  end

  defp parse_condition_type("ROLLOUT"), do: :rollout
  defp parse_condition_type("WHITELIST"), do: :whitelist
  defp parse_condition_type(_), do: :rollout
end
