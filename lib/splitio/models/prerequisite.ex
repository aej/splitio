defmodule Splitio.Models.Prerequisite do
  @moduledoc "Feature flag dependency"

  @type t :: %__MODULE__{
          feature_flag: String.t(),
          treatments: [String.t()]
        }

  @enforce_keys [:feature_flag, :treatments]
  defstruct [:feature_flag, :treatments]

  @spec from_json(map()) :: t()
  def from_json(%{"n" => name, "ts" => treatments}) do
    %__MODULE__{feature_flag: name, treatments: treatments}
  end
end
