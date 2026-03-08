defmodule Splitio.Api.AuthTest do
  use ExUnit.Case, async: true

  import Mox

  alias Splitio.Api.Auth
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

  describe "get_auth_token/1" do
    test "returns auth token with push enabled", %{config: config} do
      response = Fixtures.auth_response(push_enabled: true)

      expect(Splitio.Api.HTTP.Mock, :get, fn url, _opts ->
        assert String.contains?(url, "/v2/auth")
        {:ok, response}
      end)

      assert {:ok, result} = Auth.get_auth_token(config)
      assert result["pushEnabled"] == true
      assert is_binary(result["token"])
    end

    test "returns response with push disabled", %{config: config} do
      response = Fixtures.auth_response_disabled()

      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:ok, response}
      end)

      assert {:ok, result} = Auth.get_auth_token(config)
      assert result["pushEnabled"] == false
    end

    test "handles HTTP 401 unauthorized", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, {:http_error, 401}}
      end)

      assert {:error, {:http_error, 401}} = Auth.get_auth_token(config)
    end

    test "handles network error", %{config: config} do
      expect(Splitio.Api.HTTP.Mock, :get, fn _url, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Auth.get_auth_token(config)
    end
  end
end
