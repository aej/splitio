defmodule Splitio.Engine.Matchers.Semver do
  @moduledoc """
  Semantic versioning parser and comparator.

  Supports standard semver format: MAJOR.MINOR.PATCH[-prerelease][+metadata]
  Metadata is stripped for comparison purposes.
  """

  @type t :: %__MODULE__{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer(),
          prerelease: [String.t()]
        }

  defstruct major: 0, minor: 0, patch: 0, prerelease: []

  @doc """
  Parse a semver string.

  ## Examples

      iex> Semver.parse("1.2.3")
      {:ok, %Semver{major: 1, minor: 2, patch: 3}}

      iex> Semver.parse("1.2.3-alpha.1")
      {:ok, %Semver{major: 1, minor: 2, patch: 3, prerelease: ["alpha", "1"]}}

  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(version) when is_binary(version) do
    # Strip metadata (everything after +)
    version = version |> String.split("+") |> hd()

    # Split version and prerelease
    {version_part, prerelease} =
      case String.split(version, "-", parts: 2) do
        [v] -> {v, []}
        [v, pre] -> {v, String.split(pre, ".")}
      end

    # Parse version numbers
    case String.split(version_part, ".") do
      [major, minor, patch] ->
        with {maj, ""} <- Integer.parse(major),
             {min, ""} <- Integer.parse(minor),
             {pat, ""} <- Integer.parse(patch) do
          {:ok, %__MODULE__{major: maj, minor: min, patch: pat, prerelease: prerelease}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Compare two semver structs.

  Returns:
  - `:lt` if a < b
  - `:eq` if a == b
  - `:gt` if a > b
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    # Compare major.minor.patch
    case compare_version_core(a, b) do
      :eq -> compare_prerelease(a.prerelease, b.prerelease)
      result -> result
    end
  end

  defp compare_version_core(a, b) do
    cond do
      a.major < b.major -> :lt
      a.major > b.major -> :gt
      a.minor < b.minor -> :lt
      a.minor > b.minor -> :gt
      a.patch < b.patch -> :lt
      a.patch > b.patch -> :gt
      true -> :eq
    end
  end

  # Prerelease comparison rules:
  # - Version without prerelease > version with prerelease (1.0.0 > 1.0.0-alpha)
  # - Compare identifiers left to right
  # - Numeric identifiers compared as integers
  # - Alphanumeric identifiers compared lexically
  # - Numeric < alphanumeric
  defp compare_prerelease([], []), do: :eq
  defp compare_prerelease([], _), do: :gt
  defp compare_prerelease(_, []), do: :lt

  defp compare_prerelease([a | rest_a], [b | rest_b]) do
    case compare_identifier(a, b) do
      :eq -> compare_prerelease(rest_a, rest_b)
      result -> result
    end
  end

  defp compare_identifier(a, b) do
    a_numeric = numeric_identifier?(a)
    b_numeric = numeric_identifier?(b)

    cond do
      a_numeric and b_numeric ->
        compare_integers(String.to_integer(a), String.to_integer(b))

      a_numeric ->
        :lt

      b_numeric ->
        :gt

      true ->
        compare_strings(a, b)
    end
  end

  defp numeric_identifier?(s), do: Regex.match?(~r/^\d+$/, s)

  defp compare_integers(a, b) when a < b, do: :lt
  defp compare_integers(a, b) when a > b, do: :gt
  defp compare_integers(_, _), do: :eq

  defp compare_strings(a, b) when a < b, do: :lt
  defp compare_strings(a, b) when a > b, do: :gt
  defp compare_strings(_, _), do: :eq

  @doc "Check if a == b"
  @spec equal?(t(), t()) :: boolean()
  def equal?(a, b), do: compare(a, b) == :eq

  @doc "Check if a >= b"
  @spec gte?(t(), t()) :: boolean()
  def gte?(a, b), do: compare(a, b) in [:eq, :gt]

  @doc "Check if a <= b"
  @spec lte?(t(), t()) :: boolean()
  def lte?(a, b), do: compare(a, b) in [:eq, :lt]

  @doc "Check if start <= value <= end"
  @spec between?(t(), t(), t()) :: boolean()
  def between?(value, start_v, end_v) do
    gte?(value, start_v) and lte?(value, end_v)
  end
end
