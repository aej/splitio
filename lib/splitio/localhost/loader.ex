defmodule Splitio.Localhost.Loader do
  @moduledoc false

  alias Splitio.Localhost.{JsonParser, YamlParser}
  alias Splitio.Models.Segment
  alias Splitio.Storage

  @spec load(String.t(), String.t() | nil) :: {:ok, %{splits: non_neg_integer(), segments: non_neg_integer()}} | {:error, term()}
  def load(split_file, segment_directory \\ nil) when is_binary(split_file) do
    with {:ok, splits} <- load_splits(split_file),
         {:ok, segments} <- load_segments(segment_directory) do
      reset_storage()
      Enum.each(splits, &Storage.put_split/1)
      Enum.each(segments, &Storage.put_segment/1)
      Storage.set_splits_change_number(max_change_number(splits))

      {:ok, %{splits: length(splits), segments: length(segments)}}
    end
  end

  defp load_splits(path) do
    cond do
      String.ends_with?(path, ".yaml") or String.ends_with?(path, ".yml") -> YamlParser.parse_file(path)
      String.ends_with?(path, ".json") -> JsonParser.parse_file(path)
      true -> {:error, :unknown_format}
    end
  end

  defp load_segments(nil), do: {:ok, []}
  defp load_segments(""), do: {:ok, []}

  defp load_segments(directory) do
    with {:ok, files} <- File.ls(directory) do
      segments =
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
          path = Path.join(directory, file)

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, json} when is_map(json) ->
                  {:cont, {:ok, [Segment.from_json(json) | acc]}}

                {:ok, _json} ->
                  {:halt, {:error, {:invalid_segment_file, path}}}

                {:error, reason} ->
                  {:halt, {:error, {:invalid_segment_json, path, reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:segment_read_error, path, reason}}}
          end
        end)

      case segments do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        {:error, _} = error -> error
      end
    end
  end

  defp reset_storage do
    Enum.each(Storage.get_split_names(), &Storage.delete_split/1)
    Enum.each(Storage.get_segment_names(), &Storage.delete_segment/1)
    Storage.set_splits_change_number(-1)
    Storage.set_rule_based_segments_change_number(-1)
  end

  defp max_change_number([]), do: -1
  defp max_change_number(splits), do: Enum.max_by(splits, & &1.change_number).change_number
end
