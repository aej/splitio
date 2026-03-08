# Splitio

Elixir SDK for [Split.io](https://split.io) feature flags with local evaluation.

## Features

- Local evaluation of feature flags using cached data
- Hybrid streaming (SSE) + polling synchronization
- Multiple operation modes: standalone and localhost
- Impression deduplication and batched sending
- Support for all 23+ matcher types
- OTP-based architecture with supervision trees

## Installation

Add `splitio` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:splitio, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Start the SDK
Splitio.start(api_key: "your-sdk-key")

# Wait for SDK to be ready
:ok = Splitio.block_until_ready(10_000)

# Get treatment
treatment = Splitio.get_treatment("user123", "my_feature")

case treatment do
  "on" -> # feature enabled
  "off" -> # feature disabled
  _ -> # other variant or control
end

# Get treatment with config
{treatment, config} = Splitio.get_treatment_with_config("user123", "my_feature")

# Track events
Splitio.track("user123", "user", "purchase", 99.99, %{item: "widget"})

# Shutdown
Splitio.destroy()
```

## Configuration

```elixir
Splitio.start(
  api_key: "your-sdk-key",
  mode: :standalone,              # :standalone | :localhost
  streaming_enabled: true,        # Enable SSE streaming
  impressions_mode: :optimized,   # :optimized | :debug | :none
  features_refresh_rate: 30,      # Seconds between split fetches
  segments_refresh_rate: 60,      # Seconds between segment fetches
  labels_enabled: true            # Include labels in impressions
)
```

### Localhost Mode

For development/testing without Split.io backend:

```elixir
Splitio.start(
  api_key: "localhost",
  mode: :localhost,
  split_file: "config/splits.yaml"
)
```

YAML format:
```yaml
- my_feature:
    treatment: "on"
    config: '{"color": "blue"}'
    keys:
      - user123
      - user456
```

## Manager API

```elixir
# List all splits
splits = Splitio.Manager.splits()

# Get single split
split = Splitio.Manager.split("my_feature")

# Get split names
names = Splitio.Manager.split_names()
```

## License

MIT
