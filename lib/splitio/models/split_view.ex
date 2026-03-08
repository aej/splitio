defmodule Splitio.Models.SplitView do
  @moduledoc "Public view of a feature flag for Manager API"

  alias Splitio.Models.Split

  @type t :: %__MODULE__{
          name: String.t(),
          traffic_type: String.t() | nil,
          killed: boolean(),
          treatments: [String.t()],
          change_number: non_neg_integer(),
          configs: %{String.t() => String.t() | nil},
          default_treatment: String.t(),
          sets: [String.t()],
          impressions_disabled: boolean(),
          prerequisites: [%{feature: String.t(), treatments: [String.t()]}]
        }

  @enforce_keys [:name, :change_number, :default_treatment]
  defstruct [
    :name,
    :traffic_type,
    :change_number,
    :default_treatment,
    killed: false,
    treatments: [],
    configs: %{},
    sets: [],
    impressions_disabled: false,
    prerequisites: []
  ]

  @spec from_split(Split.t()) :: t()
  def from_split(%Split{} = split) do
    treatments =
      split.conditions
      |> Enum.flat_map(& &1.partitions)
      |> Enum.map(& &1.treatment)
      |> Enum.uniq()

    %__MODULE__{
      name: split.name,
      traffic_type: split.traffic_type_name,
      killed: split.killed,
      treatments: treatments,
      change_number: split.change_number,
      configs: split.configurations,
      default_treatment: split.default_treatment,
      sets: MapSet.to_list(split.sets),
      impressions_disabled: split.impressions_disabled,
      prerequisites:
        Enum.map(split.prerequisites, fn p ->
          %{feature: p.feature_flag, treatments: p.treatments}
        end)
    }
  end
end
