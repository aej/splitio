defmodule Splitio.Models.RuleBasedSegment do
  @moduledoc "Dynamic segment defined by rules"

  alias Splitio.Models.{Condition, Excluded}

  @type status :: :active | :archived

  @type t :: %__MODULE__{
          name: String.t(),
          traffic_type_name: String.t() | nil,
          change_number: non_neg_integer(),
          status: status(),
          conditions: [Condition.t()],
          excluded: Excluded.t()
        }

  @enforce_keys [:name, :change_number]
  defstruct [
    :name,
    :traffic_type_name,
    :change_number,
    status: :active,
    conditions: [],
    excluded: %Excluded{}
  ]

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"name" => name} = json) do
    {:ok,
     %__MODULE__{
       name: name,
       traffic_type_name: json["trafficTypeName"],
       change_number: json["changeNumber"] || 0,
       status: parse_status(json["status"]),
       conditions: parse_conditions(json["conditions"] || []),
       excluded: Excluded.from_json(json["excluded"])
     }}
  end

  def from_json(_), do: {:error, :invalid_rule_based_segment}

  defp parse_status("ACTIVE"), do: :active
  defp parse_status("ARCHIVED"), do: :archived
  defp parse_status(_), do: :active

  defp parse_conditions(conditions) do
    Enum.map(conditions, &Condition.from_json/1)
  end
end
