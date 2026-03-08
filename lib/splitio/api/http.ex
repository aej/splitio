defmodule Splitio.Api.HTTP do
  @moduledoc """
  HTTP client behaviour for Split API requests.

  This behaviour allows swapping implementations for testing.
  """

  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, map() | binary()} | {:error, term()}

  @callback get(url :: String.t(), opts :: keyword()) :: response()
  @callback post(url :: String.t(), body :: term(), opts :: keyword()) :: response()
end
