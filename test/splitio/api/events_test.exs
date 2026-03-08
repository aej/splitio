defmodule Splitio.Api.EventsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Splitio.Api.Events
  alias Splitio.Config

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Use mock HTTP client for these tests (process-local)
    Process.put(:splitio_http_client, Splitio.Api.HTTP.Mock)

    {:ok, config} = Config.new(api_key: "test-api-key")
    {:ok, config: config}
  end

  describe "post_impressions/3" do
    test "posts impressions bulk", %{config: config} do
      impressions = [
        %{
          "f" => "feature1",
          "i" => [
            %{"k" => "user1", "t" => "on", "m" => 1_704_067_200_000, "c" => 123, "r" => "rule"}
          ]
        }
      ]

      expect(Splitio.Api.HTTP.Mock, :post, fn url, body, opts ->
        assert String.contains?(url, "/testImpressions/bulk")
        assert body == impressions
        # Check impressions mode header
        headers = Keyword.get(opts, :headers)

        assert Enum.any?(headers, fn {k, v} ->
                 k == "splitsdkimpressionsmode" and v == "OPTIMIZED"
               end)

        {:ok, %{}}
      end)

      assert {:ok, _} = Events.post_impressions(config, impressions)
    end

    test "includes debug mode in header", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :post, fn _url, _body, opts ->
        headers = Keyword.get(opts, :headers)

        assert Enum.any?(headers, fn {k, v} -> k == "splitsdkimpressionsmode" and v == "DEBUG" end)

        {:ok, %{}}
      end)

      assert {:ok, _} = Events.post_impressions(config, [], :debug)
    end

    test "handles HTTP error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :post, fn _url, _body, _opts ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} = Events.post_impressions(config, [])
    end
  end

  describe "post_impression_counts/2" do
    test "posts impression counts", %{config: config} do
      counts = %{
        "pf" => [
          %{"f" => "feature1", "m" => 1_704_067_200_000, "rc" => 150}
        ]
      }

      expect(Splitio.Api.HTTP.Mock, :post, fn url, body, _opts ->
        assert String.contains?(url, "/testImpressions/count")
        assert body == counts
        {:ok, %{}}
      end)

      assert {:ok, _} = Events.post_impression_counts(config, counts)
    end
  end

  describe "post_events/2" do
    test "posts events bulk", %{config: config} do
      events = [
        %{
          "key" => "user1",
          "trafficTypeName" => "user",
          "eventTypeId" => "purchase",
          "value" => 99.99,
          "timestamp" => 1_704_067_200_000,
          "properties" => %{"item" => "widget"}
        }
      ]

      expect(Splitio.Api.HTTP.Mock, :post, fn url, body, _opts ->
        assert String.contains?(url, "/events/bulk")
        assert body == events
        {:ok, %{}}
      end)

      assert {:ok, _} = Events.post_events(config, events)
    end
  end

  describe "post_unique_keys/2" do
    test "posts unique keys (NONE mode)", %{config: config} do
      keys = %{
        "keys" => [
          %{"f" => "feature1", "ks" => ["user1", "user2", "user3"]}
        ]
      }

      expect(Splitio.Api.HTTP.Mock, :post, fn url, body, _opts ->
        assert String.contains?(url, "/keys/ss")
        assert body == keys
        {:ok, %{}}
      end)

      assert {:ok, _} = Events.post_unique_keys(config, keys)
    end
  end
end
