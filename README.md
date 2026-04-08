# Splitio

[![Test](https://github.com/aej/splitio/actions/workflows/test.yml/badge.svg)](https://github.com/aej/splitio/actions/workflows/test.yml)
[![Load Test](https://github.com/aej/splitio/actions/workflows/loadtest.yml/badge.svg)](https://github.com/aej/splitio/actions/workflows/loadtest.yml)

Elixir SDK for [Split.io](https://split.io) feature flags with local evaluation.

## Features

- Local evaluation of feature flags using cached data
- Streaming-first synchronization with polling fallback
- Multiple operation modes: standalone and localhost
- Impression deduplication and batched sending
- NONE-mode unique key reporting
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
  streaming_enabled: true,        # Enable SSE streaming with polling fallback
  impressions_mode: :optimized,   # :optimized | :debug | :none
  features_refresh_rate: 30,      # Seconds between split fetches
  segments_refresh_rate: 60,      # Seconds between segment fetches
  labels_enabled: true,           # Include labels in impressions
  segment_directory: nil,         # Localhost JSON segments directory
  localhost_refresh_enabled: false,
  impression_listener: nil,       # Optional callback for every generated impression
  fallback_treatment: nil         # Optional fallback treatment config
```

### Localhost Mode

For development/testing without Split.io backend:

```elixir
# config/dev.exs
config :splitio,
  api_key: "localhost",
  split_file: "config/splits.yaml",
  localhost_refresh_enabled: true
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

JSON localhost mode also supports external segment files:

```elixir
config :splitio,
  api_key: "localhost",
  split_file: "config/splits.json",
  segment_directory: "config/segments",
  localhost_refresh_enabled: true
```

### Lifecycle

```elixir
# Wait until definitions are available
:ok = Splitio.block_until_ready(10_000)

# Or through the manager facade
:ok = Splitio.Manager.block_until_ready(10_000)

# Flush pending events/impressions and stop the SDK
:ok = Splitio.destroy()
```

### SDK Events

```elixir
{:ok, _handler} =
  Splitio.on(:sdk_ready, fn _metadata ->
    IO.puts("Split SDK is ready")
  end)

{:ok, _handler} =
  Splitio.on(:sdk_update, fn metadata ->
    IO.inspect(metadata, label: "Split SDK update")
  end)
```

### Impression Listener

You can attach a callback that receives every generated impression, including ones
that are deduplicated locally in `:optimized` mode or suppressed from network
delivery in `:none` mode.

```elixir
config :splitio,
  api_key: "your-sdk-key",
  impression_listener: fn %{impression: impression, attributes: attributes} ->
    IO.inspect({impression.feature, impression.treatment, attributes})
  end
```

### Fallback Treatments

When a flag cannot be evaluated, the SDK returns `control` by default. You can
override that globally or per flag:

```elixir
config :splitio,
  api_key: "your-sdk-key",
  fallback_treatment: %{
    global: %{treatment: "off", config: %{source: "fallback"}},
    by_flag: %{
      "checkout_redesign" => %{treatment: "safe_off"}
    }
  }
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

### Using mise

This repo includes a project-level [`mise`](https://mise.jdx.dev/) config for tool versions,
tasks, and environment loading.

```bash
# install pinned Erlang/Elixir versions
mise install

# install Hex/Rebar and Elixir dependencies
mise run setup
```

`mise` loads `.env` automatically via [`mise.toml`](./mise.toml), so integration test
credentials in `.env` are available without running `source .env` first.

### Running Tests

```bash
mise run test
```

### Load Testing

Run end-to-end load tests against a mocked Split/Harness HTTP boundary. The SDK is
started as a child in a supervision tree, bootstraps through normal sync code paths,
and exercises evaluations plus recorder flushes through the public API.

```bash
# Quick local smoke test
mise run loadtest-quick

# Sustained runtime load test
mise run loadtest

# Run with impressions disabled
mise run loadtest-none

# Write machine-readable outputs
mix loadtest --ci --json-output bench/results/loadtest.json --markdown-output bench/results/loadtest.md

# Run the same two thresholded modes used in CI
mise run loadtest-ci
```

In GitHub Actions, the heavy load test runs only when the `loadtest` label is added to
the PR. Results are posted back to the PR as a comment, and the `Load Test Gate` status
must be green before a labeled PR can merge.

### Integration Tests

Integration tests run against the real Split.io API. They require credentials:

```bash
# Copy example env and fill in values
cp .env.example .env

# Run integration tests
mise run test-integration
```

Required environment variables (see `.env.example`):
- `SPLIT_SDK_KEY` - SDK API key for the test environment
- `SPLIT_ADMIN_KEY` - Admin API key (for creating test fixtures)
- `SPLIT_WORKSPACE_ID` - Workspace/Project ID
- `SPLIT_ENVIRONMENT_ID` - Environment ID
- `SPLIT_ENVIRONMENT_NAME` - Environment name

### CI Workflows

- **Test**: Runs on all PRs to `main` - compiles, tests, format check
- **Load Test**: Runs only when the `loadtest` label is added - checks runtime thresholds and comments results on the PR
- **Load Test Gate**: Refreshes merge status for the current PR head SHA; labeled PRs must rerun load test after new commits
- **Integration Test**: Runs when `integration` label added - tests against real Split.io API

`Run Tests`, `Integration Tests`, and `Load Test Gate` should be configured as required
status checks on `main`.

## License

MIT
