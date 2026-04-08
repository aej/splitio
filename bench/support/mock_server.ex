defmodule Splitio.Bench.MockServer do
  @moduledoc """
  Stateful mock Split/Harness boundary for load tests.

  This owns the mocked split/segment payloads and records outbound POST activity
  from the SDK recorders so the load test can assert on end-to-end behavior.
  """

  use GenServer

  @type dataset :: %{
          change_number: integer(),
          splits: [map()],
          segment_changes: %{optional(String.t()) => map()}
        }

  @type stats :: %{
          split_fetches: non_neg_integer(),
          segment_fetches: non_neg_integer(),
          event_posts: non_neg_integer(),
          event_items: non_neg_integer(),
          impression_posts: non_neg_integer(),
          impression_items: non_neg_integer(),
          impression_count_posts: non_neg_integer(),
          impression_count_items: non_neg_integer(),
          unique_key_posts: non_neg_integer(),
          unique_key_items: non_neg_integer(),
          post_failures: non_neg_integer()
        }

  def start_link(opts) do
    dataset = Keyword.fetch!(opts, :dataset)
    GenServer.start_link(__MODULE__, dataset, name: __MODULE__)
  end

  @spec stats() :: stats()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(url, opts) do
    GenServer.call(__MODULE__, {:get, url, opts})
  end

  @spec post(String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, opts) do
    GenServer.call(__MODULE__, {:post, url, body, opts})
  end

  @impl true
  def init(dataset) do
    {:ok, %{dataset: dataset, stats: empty_stats()}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call({:get, url, opts}, _from, state) do
    path = URI.parse(url).path || ""
    params = Keyword.get(opts, :params, [])

    {response, stats} =
      cond do
        String.ends_with?(path, "/splitChanges") ->
          since = Keyword.get(params, :since, -1)
          {split_changes_response(state.dataset, since), bump(state.stats, :split_fetches)}

        String.contains?(path, "/segmentChanges/") ->
          segment_name = segment_name_from_path(path)
          since = Keyword.get(params, :since, -1)

          response =
            state.dataset.segment_changes
            |> Map.get(segment_name, empty_segment_response(segment_name, state.dataset.change_number))
            |> maybe_empty_since(since)

          {response, bump(state.stats, :segment_fetches)}

        true ->
          {{:error, {:unexpected_get, path}}, state.stats}
      end

    case response do
      {:error, _} = error ->
        {:reply, error, %{state | stats: stats}}

      body ->
        {:reply, {:ok, body}, %{state | stats: stats}}
    end
  end

  def handle_call({:post, url, body, _opts}, _from, state) do
    path = URI.parse(url).path || ""
    {response, stats} = handle_post(path, body, state.stats)

    case response do
      {:error, _} = error ->
        {:reply, error, %{state | stats: stats}}

      body ->
        {:reply, {:ok, body}, %{state | stats: stats}}
    end
  end

  defp handle_post(path, body, stats) do
    cond do
      String.ends_with?(path, "/events/bulk") ->
        stats =
          stats
          |> bump(:event_posts)
          |> bump_by(:event_items, length(List.wrap(body)))

        {%{}, stats}

      String.ends_with?(path, "/testImpressions/bulk") ->
        item_count =
          body
          |> List.wrap()
          |> Enum.reduce(0, fn group, acc ->
            acc + length(Map.get(group, "i", []))
          end)

        stats =
          stats
          |> bump(:impression_posts)
          |> bump_by(:impression_items, item_count)

        {%{}, stats}

      String.ends_with?(path, "/testImpressions/count") ->
        count_items = body |> Map.get("pf", []) |> length()

        stats =
          stats
          |> bump(:impression_count_posts)
          |> bump_by(:impression_count_items, count_items)

        {%{}, stats}

      String.ends_with?(path, "/keys/ss") ->
        unique_items =
          body
          |> Map.get("keys", [])
          |> length()

        stats =
          stats
          |> bump(:unique_key_posts)
          |> bump_by(:unique_key_items, unique_items)

        {%{}, stats}

      true ->
        stats = bump(stats, :post_failures)
        {{:error, {:unexpected_post, path}}, stats}
    end
  end

  defp split_changes_response(dataset, since) when since < dataset.change_number do
    %{
      "splits" => dataset.splits,
      "since" => since,
      "till" => dataset.change_number
    }
  end

  defp split_changes_response(dataset, since) do
    %{
      "splits" => [],
      "since" => since,
      "till" => dataset.change_number
    }
  end

  defp maybe_empty_since(response, since) do
    till = Map.get(response, "till", since)

    if since < till do
      response
    else
      %{
        "name" => Map.get(response, "name"),
        "added" => [],
        "removed" => [],
        "since" => since,
        "till" => till
      }
    end
  end

  defp empty_segment_response(name, change_number) do
    %{
      "name" => name,
      "added" => [],
      "removed" => [],
      "since" => change_number,
      "till" => change_number
    }
  end

  defp segment_name_from_path(path) do
    path
    |> String.split("/segmentChanges/")
    |> List.last()
  end

  defp empty_stats do
    %{
      split_fetches: 0,
      segment_fetches: 0,
      event_posts: 0,
      event_items: 0,
      impression_posts: 0,
      impression_items: 0,
      impression_count_posts: 0,
      impression_count_items: 0,
      unique_key_posts: 0,
      unique_key_items: 0,
      post_failures: 0
    }
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))
  defp bump_by(stats, key, value), do: Map.update!(stats, key, &(&1 + value))
end
