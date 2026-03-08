defmodule Splitio.Models.Split do
  @moduledoc "Feature flag definition"

  alias Splitio.Models.{Condition, Prerequisite}

  @type status :: :active | :archived
  @type algo :: :legacy | :murmur

  @type t :: %__MODULE__{
          name: String.t(),
          traffic_type_name: String.t() | nil,
          killed: boolean(),
          status: status(),
          default_treatment: String.t(),
          change_number: non_neg_integer(),
          algo: algo(),
          traffic_allocation: 0..100,
          traffic_allocation_seed: integer() | nil,
          seed: integer() | nil,
          conditions: [Condition.t()],
          configurations: %{String.t() => String.t() | nil},
          sets: MapSet.t(String.t()),
          impressions_disabled: boolean(),
          prerequisites: [Prerequisite.t()]
        }

  @enforce_keys [:name, :default_treatment, :change_number]
  defstruct [
    :name,
    :traffic_type_name,
    :default_treatment,
    :change_number,
    :seed,
    :traffic_allocation_seed,
    killed: false,
    status: :active,
    algo: :murmur,
    traffic_allocation: 100,
    conditions: [],
    configurations: %{},
    sets: MapSet.new(),
    impressions_disabled: false,
    prerequisites: []
  ]

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"name" => name} = json) do
    {:ok,
     %__MODULE__{
       name: name,
       traffic_type_name: json["trafficTypeName"],
       killed: json["killed"] || false,
       status: parse_status(json["status"]),
       default_treatment: json["defaultTreatment"] || "control",
       change_number: json["changeNumber"] || 0,
       algo: parse_algo(json["algo"]),
       traffic_allocation: json["trafficAllocation"] || 100,
       traffic_allocation_seed: json["trafficAllocationSeed"],
       seed: json["seed"],
       conditions: parse_conditions(json["conditions"] || []),
       configurations: json["configurations"] || %{},
       sets: MapSet.new(json["sets"] || []),
       impressions_disabled: json["impressionsDisabled"] || false,
       prerequisites: parse_prerequisites(json["prerequisites"] || [])
     }}
  end

  def from_json(_), do: {:error, :invalid_split}

  @doc "Get configuration for a treatment"
  @spec get_config(t(), String.t()) :: String.t() | nil
  def get_config(%__MODULE__{configurations: configs}, treatment) do
    Map.get(configs, treatment)
  end

  defp parse_status("ACTIVE"), do: :active
  defp parse_status("ARCHIVED"), do: :archived
  defp parse_status(_), do: :active

  defp parse_algo(1), do: :legacy
  defp parse_algo(2), do: :murmur
  defp parse_algo(_), do: :murmur

  defp parse_conditions(conditions) do
    Enum.map(conditions, &Condition.from_json/1)
  end

  defp parse_prerequisites(prereqs) do
    Enum.map(prereqs, &Prerequisite.from_json/1)
  end
end
