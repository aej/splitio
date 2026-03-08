ExUnit.start()

# Define Mox mock for HTTP client
Mox.defmock(Splitio.Api.HTTP.Mock, for: Splitio.Api.HTTP)

# Start ETS table owner for tests
{:ok, _} = Splitio.Storage.TableOwner.start_link([])
