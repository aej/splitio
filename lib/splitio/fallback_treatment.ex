defmodule Splitio.FallbackTreatment do
  @moduledoc false

  alias Splitio.Config

  @spec resolve(String.t(), String.t() | nil) :: {String.t(), String.t() | nil}
  def resolve(split_name, default_treatment \\ "control") do
    case Application.get_env(:splitio, :config) do
      %Config{fallback_treatment: fallback} ->
        resolve_from_config(split_name, default_treatment, fallback)

      _ ->
        {default_treatment, nil}
    end
  end

  defp resolve_from_config(_split_name, default_treatment, nil), do: {default_treatment, nil}

  defp resolve_from_config(split_name, default_treatment, fallback) do
    entry =
      get_in(fallback, [:by_flag, split_name]) ||
        get_in(fallback, ["by_flag", split_name]) ||
        Map.get(fallback, :global) ||
        Map.get(fallback, "global")

    case entry do
      %{treatment: treatment} = fallback_entry when is_binary(treatment) and treatment != "" ->
        {treatment, Map.get(fallback_entry, :config)}

      %{"treatment" => treatment} = fallback_entry
      when is_binary(treatment) and treatment != "" ->
        {treatment, Map.get(fallback_entry, "config")}

      _ ->
        {default_treatment, nil}
    end
  end
end
