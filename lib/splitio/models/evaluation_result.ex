defmodule Splitio.Models.EvaluationResult do
  @moduledoc "Result of evaluating a feature flag"

  @type t :: %__MODULE__{
          treatment: String.t(),
          label: String.t(),
          config: String.t() | nil,
          change_number: non_neg_integer(),
          impressions_disabled: boolean()
        }

  @enforce_keys [:treatment, :label, :change_number]
  defstruct [
    :treatment,
    :label,
    :config,
    :change_number,
    impressions_disabled: false
  ]
end
