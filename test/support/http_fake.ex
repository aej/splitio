defmodule Splitio.TestHTTP do
  @behaviour Splitio.Api.HTTP

  @handler_key {__MODULE__, :handler}

  def set_handler(handler) when is_function(handler, 4) do
    :persistent_term.put(@handler_key, handler)
  end

  def clear_handler do
    :persistent_term.erase(@handler_key)
  end

  @impl true
  def get(url, opts \\ []) do
    call(:get, url, nil, opts)
  end

  @impl true
  def post(url, body, opts \\ []) do
    call(:post, url, body, opts)
  end

  defp call(method, url, body, opts) do
    handler = :persistent_term.get(@handler_key, &default_handler/4)
    handler.(method, url, body, opts)
  end

  defp default_handler(_method, _url, _body, _opts) do
    {:error, :no_test_http_handler}
  end
end
