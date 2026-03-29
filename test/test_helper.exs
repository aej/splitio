# Exclude integration tests by default (run with: mix test --only integration)
ExUnit.start(exclude: [:integration])

# Define Mox mock for HTTP client
Mox.defmock(Splitio.Api.HTTP.Mock, for: Splitio.Api.HTTP)

# Start ETS table owner for tests
# Integration tests start the full SDK which creates its own tables,
# but having it already started is fine (TableOwner handles this)
{:ok, _} = Splitio.Storage.TableOwner.start_link([])
