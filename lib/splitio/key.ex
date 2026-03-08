defmodule Splitio.Key do
  @moduledoc "Composite key for evaluation"

  @type t :: %__MODULE__{
          matching_key: String.t(),
          bucketing_key: String.t() | nil
        }

  @enforce_keys [:matching_key]
  defstruct [:matching_key, :bucketing_key]

  @doc "Create key from string or struct"
  @spec new(String.t() | t()) :: t()
  def new(%__MODULE__{} = key), do: key
  def new(key) when is_binary(key), do: %__MODULE__{matching_key: key}

  @doc "Create key with separate matching and bucketing keys"
  @spec new(String.t(), String.t() | nil) :: t()
  def new(matching_key, bucketing_key) when is_binary(matching_key) do
    %__MODULE__{matching_key: matching_key, bucketing_key: bucketing_key}
  end

  @doc "Get the bucketing key (falls back to matching key)"
  @spec bucketing_key(t()) :: String.t()
  def bucketing_key(%__MODULE__{bucketing_key: nil, matching_key: mk}), do: mk
  def bucketing_key(%__MODULE__{bucketing_key: bk}), do: bk

  @doc "Get the matching key"
  @spec matching_key(t()) :: String.t()
  def matching_key(%__MODULE__{matching_key: mk}), do: mk
end
