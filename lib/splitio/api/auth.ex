defmodule Splitio.Api.Auth do
  @moduledoc """
  Auth API client for streaming authentication.
  """

  alias Splitio.Api.Client
  alias Splitio.Config

  @doc """
  Get streaming auth token.

  Returns JWT token and streaming configuration.
  """
  @spec get_auth_token(Config.t()) :: {:ok, map()} | {:error, term()}
  def get_auth_token(%Config{} = config) do
    Client.get(config, config.auth_url, "/v2/auth")
  end
end
