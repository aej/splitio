defmodule Splitio.Sync.SplitsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Splitio.Sync.Splits
  alias Splitio.Config
  alias Splitio.Storage
  alias Splitio.Test.Fixtures

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Process.put(:splitio_http_client, Splitio.Api.HTTP.Mock)

    # Reset storage state
    Storage.set_splits_change_number(-1)

    {:ok, config} = Config.new(api_key: "test-api-key")
    {:ok, config: config}
  end

  describe "sync/1" do
    test "syncs initial splits from API", %{config: config} do
      split = Fixtures.default_split(name: "feature1", treatment: "on")
      response1 = Fixtures.split_changes_response(splits: [split], since: -1, till: 1000)
      response2 = Fixtures.split_changes_empty(1000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn url, opts ->
        assert String.contains?(url, "/splitChanges")
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
        end
      end)

      assert {:ok, segments} = Splits.sync(config)
      assert is_list(segments)

      # Verify split was stored
      assert {:ok, stored} = Storage.get_split("feature1")
      assert stored.name == "feature1"
      assert stored.default_treatment == "off"
    end

    test "extracts segment names from conditions", %{config: config} do
      split = Fixtures.split_with_segment("feature1", "beta_users")
      response1 = Fixtures.split_changes_response(splits: [split], since: -1, till: 1000)
      response2 = Fixtures.split_changes_empty(1000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
        end
      end)

      assert {:ok, segments} = Splits.sync(config)
      assert "beta_users" in segments
    end

    test "paginates when more changes exist", %{config: config} do
      # First response has more data
      split1 = Fixtures.default_split(name: "feature1")
      response1 = Fixtures.split_changes_response(splits: [split1], since: -1, till: 1000)

      # Second response is final
      split2 = Fixtures.default_split(name: "feature2")
      response2 = Fixtures.split_changes_response(splits: [split2], since: 1000, till: 2000)

      # Third response indicates no more changes
      response3 = Fixtures.split_changes_empty(2000)

      expect(Splitio.Api.HTTP.Mock, :get, 3, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
          2000 -> {:ok, response3}
        end
      end)

      assert {:ok, _segments} = Splits.sync(config)

      # Both splits should be stored
      assert {:ok, _} = Storage.get_split("feature1")
      assert {:ok, _} = Storage.get_split("feature2")
    end

    test "deletes archived splits", %{config: config} do
      # First, add a split
      split = Fixtures.default_split(name: "to_archive")
      Storage.put_split(Splitio.Models.Split.from_json(split) |> elem(1))

      # Then receive archived version
      archived = Fixtures.archived_split("to_archive")
      response1 = Fixtures.split_changes_response(splits: [archived], since: -1, till: 2000)
      response2 = Fixtures.split_changes_empty(2000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          2000 -> {:ok, response2}
        end
      end)

      assert {:ok, _} = Splits.sync(config)

      # Split should be deleted
      assert :not_found = Storage.get_split("to_archive")
    end

    test "handles API error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} = Splits.sync(config)
    end

    test "handles network timeout", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Splits.sync(config)
    end

    test "stores change number after sync", %{config: config} do
      response1 = Fixtures.split_changes_response(since: -1, till: 5000)
      response2 = Fixtures.split_changes_empty(5000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          5000 -> {:ok, response2}
        end
      end)

      assert {:ok, _} = Splits.sync(config)
      assert Storage.get_splits_change_number() == 5000
    end

    test "includes flag sets filter in request", %{config: _config} do
      {:ok, filtered_config} =
        Config.new(api_key: "test", flag_sets_filter: ["frontend", "mobile"])

      # The fixture returns since == till so no pagination needed
      response = %{"splits" => [], "since" => -1, "till" => -1}

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:sets] == "frontend,mobile"
        {:ok, response}
      end)

      assert {:ok, _} = Splits.sync(filtered_config)
    end
  end

  describe "sync_to/2 (CDN bypass)" do
    test "forces sync to specific change number", %{config: config} do
      target_till = 3000
      response = Fixtures.split_changes_response(till: target_till)

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:till] == target_till
        {:ok, response}
      end)

      assert {:ok, _} = Splits.sync_to(config, target_till)
    end

    test "continues fetching until target reached", %{config: config} do
      response1 = Fixtures.split_changes_response(till: 2000)
      response2 = Fixtures.split_changes_response(till: 3000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        cond do
          params[:since] == -1 -> {:ok, response1}
          params[:since] == 2000 -> {:ok, response2}
        end
      end)

      assert {:ok, _} = Splits.sync_to(config, 3000)
    end
  end
end
