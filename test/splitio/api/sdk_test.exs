defmodule Splitio.Api.SDKTest do
  use ExUnit.Case, async: true

  import Mox

  alias Splitio.Api.SDK
  alias Splitio.Config
  alias Splitio.Test.Fixtures

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Use mock HTTP client for these tests (process-local)
    Process.put(:splitio_http_client, Splitio.Api.HTTP.Mock)

    {:ok, config} = Config.new(api_key: "test-api-key")
    {:ok, config: config}
  end

  describe "fetch_split_changes/2" do
    test "fetches initial split changes", %{config: config} do
      response = Fixtures.split_changes_response()

      expect(Splitio.Api.HTTP.Mock, :get, fn url, opts ->
        assert String.contains?(url, "/splitChanges")
        assert Keyword.get(opts, :params)[:since] == -1
        {:ok, response}
      end)

      assert {:ok, ^response} = SDK.fetch_split_changes(config)
    end

    test "fetches changes since specific change number", %{config: config} do
      since = 1_704_067_200_000
      response = Fixtures.split_changes_empty(since)

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        assert Keyword.get(opts, :params)[:since] == since
        {:ok, response}
      end)

      assert {:ok, ^response} = SDK.fetch_split_changes(config, since: since)
    end

    test "includes till param for CDN bypass", %{config: config} do
      till = 1_704_067_300_000

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:till] == till
        # cache-control header should be set
        headers = Keyword.get(opts, :headers)
        assert Enum.any?(headers, fn {k, v} -> k == "cache-control" and v == "no-cache" end)
        {:ok, Fixtures.split_changes_empty(till)}
      end)

      assert {:ok, _} = SDK.fetch_split_changes(config, till: till)
    end

    test "includes flag sets filter", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:sets] == "frontend,mobile"
        {:ok, Fixtures.split_changes_response()}
      end)

      assert {:ok, _} = SDK.fetch_split_changes(config, sets: ["frontend", "mobile"])
    end

    test "handles HTTP error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} = SDK.fetch_split_changes(config)
    end

    test "handles network error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = SDK.fetch_split_changes(config)
    end
  end

  describe "fetch_segment_changes/3" do
    test "fetches initial segment changes", %{config: config} do
      response = Fixtures.segment_changes_response(name: "beta_users")

      expect(Splitio.Api.HTTP.Mock, :get, fn url, opts ->
        assert String.contains?(url, "/segmentChanges/beta_users")
        assert Keyword.get(opts, :params)[:since] == -1
        {:ok, response}
      end)

      assert {:ok, ^response} = SDK.fetch_segment_changes(config, "beta_users")
    end

    test "fetches segment changes since specific change number", %{config: config} do
      since = 1_704_067_200_000
      response = Fixtures.segment_changes_empty("beta_users", since)

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        assert Keyword.get(opts, :params)[:since] == since
        {:ok, response}
      end)

      assert {:ok, ^response} = SDK.fetch_segment_changes(config, "beta_users", since: since)
    end

    test "includes till param for CDN bypass", %{config: config} do
      till = 1_704_067_300_000

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:till] == till
        {:ok, Fixtures.segment_changes_empty("test", till)}
      end)

      assert {:ok, _} = SDK.fetch_segment_changes(config, "test", till: till)
    end

    test "handles 404 for non-existent segment", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, {:http_error, 404}}
      end)

      assert {:error, {:http_error, 404}} = SDK.fetch_segment_changes(config, "nonexistent")
    end
  end

  describe "fetch_large_segment/3" do
    test "fetches large segment definition", %{config: config} do
      response = Fixtures.large_segment_response(name: "large_users")

      expect(Splitio.Api.HTTP.Mock, :get, fn url, opts ->
        assert String.contains?(url, "/largeSegmentDefinition/large_users")
        assert Keyword.get(opts, :params)[:since] == -1
        {:ok, response}
      end)

      assert {:ok, ^response} = SDK.fetch_large_segment(config, "large_users")
    end

    test "fetches with since parameter", %{config: config} do
      since = 1_704_067_200_000

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        assert Keyword.get(opts, :params)[:since] == since
        {:ok, Fixtures.large_segment_response()}
      end)

      assert {:ok, _} = SDK.fetch_large_segment(config, "test", since)
    end
  end

  describe "download_file/2" do
    test "downloads raw binary body through the configured HTTP client" do
      body = "key1\nkey2\nkey3\n"

      expect(Splitio.Api.HTTP.Mock, :get, fn url, opts ->
        assert url == "https://cdn.split.io/large-segments/test.csv"
        assert Keyword.get(opts, :headers) == [{"authorization", "Bearer token"}]
        assert Keyword.get(opts, :decode_json) == false
        {:ok, body}
      end)

      assert {:ok, ^body} =
               SDK.download_file(
                 "https://cdn.split.io/large-segments/test.csv",
                 %{"authorization" => "Bearer token"}
               )
    end
  end
end
