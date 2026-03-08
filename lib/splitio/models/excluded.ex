defmodule Splitio.Models.Excluded do
  @moduledoc "Exclusion rules for rule-based segments"

  alias Splitio.Models.ExcludedSegment

  @type t :: %__MODULE__{
          keys: MapSet.t(String.t()),
          segments: [ExcludedSegment.t()]
        }

  defstruct keys: MapSet.new(), segments: []

  @spec from_json(map() | nil) :: t()
  def from_json(nil), do: %__MODULE__{}

  def from_json(json) do
    %__MODULE__{
      keys: MapSet.new(json["keys"] || []),
      segments: Enum.map(json["segments"] || [], &ExcludedSegment.from_json/1)
    }
  end
end
