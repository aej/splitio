defmodule Splitio.Models.Partition do
  @moduledoc "Treatment allocation within a condition"

  @type t :: %__MODULE__{
          treatment: String.t(),
          size: 0..100
        }

  @enforce_keys [:treatment, :size]
  defstruct [:treatment, :size]

  @spec from_json(map()) :: t()
  def from_json(%{"treatment" => treatment, "size" => size}) do
    %__MODULE__{treatment: treatment, size: size}
  end
end
