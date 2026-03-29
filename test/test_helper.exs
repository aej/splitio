# Exclude integration tests by default (run with: mix test --only integration)
ExUnit.start(exclude: [:integration])

# Define Mox mock for HTTP client
Mox.defmock(Splitio.Api.HTTP.Mock, for: Splitio.Api.HTTP)

# Start ETS table owner for unit tests only
# Integration tests start the full SDK which creates its own tables
running_only_integration? =
  System.argv()
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.any?(fn [flag, val] -> flag == "--only" and val == "integration" end)

unless running_only_integration? do
  {:ok, _} = Splitio.Storage.TableOwner.start_link([])
end
