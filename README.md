# Splitio

[![Test](https://github.com/aej/splitio/actions/workflows/test.yml/badge.svg)](https://github.com/aej/splitio/actions/workflows/test.yml)
[![Load Test](https://github.com/aej/splitio/actions/workflows/loadtest.yml/badge.svg)](https://github.com/aej/splitio/actions/workflows/loadtest.yml)

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

**1. Configure the SDK** in your config files:

```elixir
# config/config.exs
config :splitio,
  api_key: "your-sdk-key"
```

Or use runtime config for environment variables:

```elixir
# config/runtime.exs
config :splitio,
  api_key: System.fetch_env!("SPLIT_API_KEY")
```

**2. Add to your supervision tree** in `lib/my_app/application.ex`:

```elixir
def start(_type, _args) do
  children = [
    # ... other children
    Splitio
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

**3. Use feature flags** in your application:

```elixir
# Wait for SDK to be ready (optional, e.g., at startup)
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
```

## Configuration

All options go under the `:splitio` application config:

```elixir
# config/config.exs
config :splitio,
  api_key: "your-sdk-key",
  mode: :standalone,              # :standalone | :localhost
  streaming_enabled: true,        # Enable SSE streaming
  impressions_mode: :optimized,   # :optimized | :debug | :none
  features_refresh_rate: 30,      # Seconds between split fetches
  segments_refresh_rate: 60,      # Seconds between segment fetches
  labels_enabled: true            # Include labels in impressions
```

### Localhost Mode

For development/testing without Split.io backend:

```elixir
# config/dev.exs
config :splitio,
  api_key: "localhost",
  mode: :localhost,
  split_file: "config/splits.yaml"
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

## Development

### Running Tests

```bash
mix test
```

### Load Testing

Run load tests to benchmark SDK performance:

```bash
# Quick benchmark
mix loadtest --quick

# Full benchmark suite
mix loadtest

# Sustained load test only
mix loadtest --sustained --processes 100 --duration 10

# Test with impressions disabled (fastest)
mix loadtest --quick --impressions none

# CI mode (checks against thresholds, exits non-zero on failure)
mix loadtest --sustained --ci
```

### Performance Baselines

| Scenario | Impressions Mode | Throughput | Latency |
|----------|------------------|------------|---------|
| `get_treatment` (simple) | optimized | ~35K ops/sec | ~29us |
| `get_treatment` (segment) | optimized | ~23K ops/sec | ~44us |
| `get_treatment` (random) | optimized | ~18K ops/sec | ~55us |
| `track` | - | ~32K ops/sec | ~31us |
| 100-process sustained | optimized | ~34K ops/sec | - |
| 100-process sustained | none | ~178K ops/sec | - |

### Integration Tests

Integration tests run against the real Split.io API. They require credentials:

```bash
# Copy example env and fill in values
cp .env.example .env

# Source the env file
source .env

# Run integration tests
mix test --only integration
```

Required environment variables (see `.env.example`):
- `SPLIT_SDK_KEY` - SDK API key for the test environment
- `SPLIT_ADMIN_KEY` - Admin API key (for creating test fixtures)
- `SPLIT_WORKSPACE_ID` - Workspace/Project ID
- `SPLIT_ENVIRONMENT_ID` - Environment ID
- `SPLIT_ENVIRONMENT_NAME` - Environment name

### CI Workflows

- **Test**: Runs on all PRs to `main` - compiles, tests, format check
- **Load Test**: Runs when `loadtest` label added - checks performance thresholds
- **Integration Test**: Runs when `integration` label added - tests against real Split.io API

All three checks must pass before merging to `main`.

## License

MIT
