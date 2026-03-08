ExUnit.start()

# Start ETS table owner for tests
{:ok, _} = Splitio.Storage.TableOwner.start_link([])
