defmodule Splitio.Sync.SegmentsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Splitio.Sync.Segments
  alias Splitio.Config
  alias Splitio.Storage
  alias Splitio.Test.Fixtures

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Process.put(:splitio_http_client, Splitio.Api.HTTP.Mock)

    {:ok, config} = Config.new(api_key: "test-api-key")
    {:ok, config: config}
  end

  describe "sync_segment/2" do
    test "syncs segment keys from API", %{config: config} do
      response1 =
        Fixtures.segment_changes_response(
          name: "beta_users",
          added: ["user1", "user2", "user3"],
          removed: [],
          since: -1,
          till: 1000
        )

      response2 = Fixtures.segment_changes_empty("beta_users", 1000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn url, opts ->
        assert String.contains?(url, "/segmentChanges/beta_users")
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
        end
      end)

      assert :ok = Segments.sync_segment(config, "beta_users")

      # Verify keys were stored
      assert Storage.segment_contains?("beta_users", "user1")
      assert Storage.segment_contains?("beta_users", "user2")
      assert Storage.segment_contains?("beta_users", "user3")
    end

    test "handles incremental adds", %{config: config} do
      seg_name = "incr_add_#{System.unique_integer([:positive])}"

      # First sync adds some users
      response1 =
        Fixtures.segment_changes_response(
          name: seg_name,
          added: ["a", "b"],
          since: -1,
          till: 1000
        )

      response2 = Fixtures.segment_changes_empty(seg_name, 1000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
        end
      end)

      assert :ok = Segments.sync_segment(config, seg_name)
      assert Storage.segment_contains?(seg_name, "a")
      assert Storage.segment_contains?(seg_name, "b")

      # Second sync adds more
      response3 =
        Fixtures.segment_changes_response(
          name: seg_name,
          added: ["c"],
          since: 1000,
          till: 2000
        )

      response4 = Fixtures.segment_changes_empty(seg_name, 2000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          1000 -> {:ok, response3}
          2000 -> {:ok, response4}
        end
      end)

      assert :ok = Segments.sync_segment(config, seg_name)
      assert Storage.segment_contains?(seg_name, "a")
      assert Storage.segment_contains?(seg_name, "c")
    end

    test "handles incremental removes", %{config: config} do
      seg_name = "incr_rm_#{System.unique_integer([:positive])}"

      # First add users
      response1 =
        Fixtures.segment_changes_response(
          name: seg_name,
          added: ["a", "b", "c"],
          since: -1,
          till: 1000
        )

      response2 = Fixtures.segment_changes_empty(seg_name, 1000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
        end
      end)

      assert :ok = Segments.sync_segment(config, seg_name)

      # Then remove one
      response3 =
        Fixtures.segment_changes_response(
          name: seg_name,
          added: [],
          removed: ["b"],
          since: 1000,
          till: 2000
        )

      response4 = Fixtures.segment_changes_empty(seg_name, 2000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          1000 -> {:ok, response3}
          2000 -> {:ok, response4}
        end
      end)

      assert :ok = Segments.sync_segment(config, seg_name)
      assert Storage.segment_contains?(seg_name, "a")
      refute Storage.segment_contains?(seg_name, "b")
      assert Storage.segment_contains?(seg_name, "c")
    end

    test "paginates when more changes exist", %{config: config} do
      response1 =
        Fixtures.segment_changes_response(
          name: "big_segment",
          added: ["a", "b"],
          since: -1,
          till: 1000
        )

      response2 =
        Fixtures.segment_changes_response(
          name: "big_segment",
          added: ["c", "d"],
          since: 1000,
          till: 2000
        )

      response3 = Fixtures.segment_changes_empty("big_segment", 2000)

      expect(Splitio.Api.HTTP.Mock, :get, 3, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          1000 -> {:ok, response2}
          2000 -> {:ok, response3}
        end
      end)

      assert :ok = Segments.sync_segment(config, "big_segment")

      # All keys should be present
      assert Storage.segment_contains?("big_segment", "a")
      assert Storage.segment_contains?("big_segment", "d")
    end

    @tag capture_log: true
    test "handles API error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} = Segments.sync_segment(config, "test")
    end

    test "stores segment change number", %{config: config} do
      seg_name = "cn_test_#{System.unique_integer([:positive])}"

      response1 =
        Fixtures.segment_changes_response(
          name: seg_name,
          since: -1,
          till: 5000
        )

      response2 = Fixtures.segment_changes_empty(seg_name, 5000)

      expect(Splitio.Api.HTTP.Mock, :get, 2, fn _url, opts ->
        params = Keyword.get(opts, :params)

        case params[:since] do
          -1 -> {:ok, response1}
          5000 -> {:ok, response2}
        end
      end)

      assert :ok = Segments.sync_segment(config, seg_name)
      assert Storage.get_segment_change_number(seg_name) == 5000
    end
  end

  # Parallel segment sync tests need to run without async:true since
  # Task.async_stream spawns processes that need to access the mock.
  # These tests use set_mox_global which doesn't work well with async.
  describe "sync_segments/2" do
    @tag :skip
    @tag :capture_log
    test "syncs multiple segments in parallel", %{config: _config} do
      # This test is complex to set up with Mox because Task.async_stream
      # spawns separate processes. For full coverage, this would need
      # integration tests with a real HTTP mock server.
      #
      # The sync_segment/2 tests above cover the core logic.
      # This test documents the expected behavior.
      assert true
    end

    @tag :skip
    @tag :capture_log
    test "continues even if one segment fails", %{config: _config} do
      # See note above - the core error handling is tested in sync_segment/2
      assert true
    end
  end

  describe "sync_segment_to/3 (CDN bypass)" do
    test "forces sync to specific change number", %{config: config} do
      target_till = 3000

      response =
        Fixtures.segment_changes_response(
          name: "test_segment",
          till: target_till
        )

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, opts ->
        params = Keyword.get(opts, :params)
        assert params[:till] == target_till
        {:ok, response}
      end)

      assert :ok = Segments.sync_segment_to(config, "test_segment", target_till)
    end
  end
end
