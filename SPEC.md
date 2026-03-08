# Split SDK Specification

Reference implementation: [splitio/go-client](https://github.com/splitio/go-client) + [splitio/go-split-commons](https://github.com/splitio/go-split-commons)

---

## Overview

Feature flag SDK that evaluates treatments locally using cached data synchronized from Split's backend.

**Core principle**: Data is fetched/pushed from Split servers and stored locally. All evaluations happen against local storage - no network calls during `get_treatment()`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Factory                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │    Client    │  │   Manager    │  │       Config          │ │
│  │ - treatment  │  │ - splits     │  │ - operation_mode      │ │
│  │ - treatments │  │ - split      │  │ - refresh_rates       │ │
│  │ - track      │  │ - names      │  │ - streaming_enabled   │ │
│  └──────┬───────┘  └──────────────┘  └───────────────────────┘ │
└─────────┼───────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Evaluator                                │
│  - condition matching                                           │
│  - traffic allocation                                           │
│  - bucketing (murmur3 hash)                                     │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Storage Layer                              │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │    Splits    │  │   Segments   │  │ Impressions/Events    │ │
│  └──────────────┘  └──────────────┘  └───────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Synchronization Layer                         │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                 Sync Manager                              │  │
│  │  ┌────────────┐  ┌────────────┐  ┌─────────────────────┐ │  │
│  │  │  Polling   │  │ Streaming  │  │  Background Tasks   │ │  │
│  │  │ (fallback) │  │   (SSE)    │  │  - impression send  │ │  │
│  │  │            │  │            │  │  - event send       │ │  │
│  │  │            │  │            │  │  - telemetry        │ │  │
│  │  └────────────┘  └────────────┘  └─────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Split Backend APIs                           │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │   SDK API    │  │  Events API  │  │   Auth/Streaming      │ │
│  └──────────────┘  └──────────────┘  └───────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Operation Modes

| Mode | Description |
|------|-------------|
| `in_memory_standalone` | Fetches from Split servers, stores in memory (default) |
| `redis_consumer` | Reads from Redis (requires external Split Synchronizer) |
| `localhost` | Reads from local YAML file (development) |

---

## Data Synchronization

### Hybrid Streaming + Polling

Primary: **SSE streaming** for real-time updates
Fallback: **HTTP polling** when streaming unavailable

### Initial Bootstrap

```
1. GET /splitChanges?since=-1
   → Paginate until response.since == response.till
   
2. For each segment referenced in splits:
   GET /segmentChanges/{name}?since=-1
   → Paginate until response.since == response.till
```

### Change Number Protocol

Every split/segment has a monotonically increasing `changeNumber`.

| Field | Purpose |
|-------|---------|
| `since` | Last known changeNumber (in request) |
| `till` | Newest changeNumber (in response) |

- `since < till` → more changes exist, keep fetching
- `since == till` → fully synced

### Streaming (SSE)

**Connection flow:**
```
1. GET /api/v2/auth → JWT token with channel capabilities
2. Connect to Ably SSE with token + channels
3. Receive real-time events
4. Auto-refresh token before expiry (token life - 10min grace)
```

**Event types:**

| Event | Action |
|-------|--------|
| `SPLIT_UPDATE` | Fetch or apply inline definition |
| `SPLIT_KILL` | Immediately kill split locally |
| `SEGMENT_UPDATE` | Fetch segment changes |
| `CONTROL` | STREAMING_ENABLED / STREAMING_PAUSED / STREAMING_DISABLED |

**Optimistic updates:**

SSE messages include:
- `pcn` (previous change number)
- `d` (base64 encoded definition, optional)
- `c` (compression type: 0=none, 1=gzip, 2=zlib)

If local changeNumber == `pcn`, apply `d` directly without HTTP fetch.
If mismatch → fall back to HTTP fetch.

### Polling (Fallback)

Triggers:
- Streaming disabled in config
- SSE connection lost
- Control message: `STREAMING_PAUSED` or `STREAMING_DISABLED`
- Zero publishers (occupancy = 0)
- Non-retryable error

Configurable refresh rates for splits and segments.

### CDN Bypass

When streaming reports changeNumber X but polling returns stale data:
```
GET /splitChanges?since={current}&till={target}
```
The `till` param forces origin fetch, bypassing CDN cache.

---

## Sync State Machine

```
┌────────────┐
│  StatusUp  │ ◄─── Streaming active
└─────┬──────┘
      │
      ├──── occupancy=0 ────────────▶ StatusDown (start polling)
      ├──── STREAMING_PAUSED ───────▶ StatusDown (start polling)
      ├──── STREAMING_DISABLED ─────▶ NonRetryableError (permanent polling)
      ├──── SSE disconnect ─────────▶ RetryableError (reconnect + backoff)
      └──── Ably error 40140-40149 ─▶ RetryableError (reconnect + backoff)

┌────────────┐
│ StatusDown │ ◄─── Polling active, streaming paused
└─────┬──────┘
      │
      └──── occupancy>0 + STREAMING_ENABLED ──▶ StatusUp (stop polling)
```

**Recovery actions:**
- `StatusUp`: Stop polling, sync all, enable streaming
- `StatusDown`: Sync all, start polling, keep streaming workers alive
- `RetryableError`: Stop streaming, sync all, start polling, backoff, retry connect
- `NonRetryableError`: Stop streaming, sync all, permanent polling mode

**Backoff strategy:**
- Base: 10 seconds
- Max wait: 60 seconds
- Max retries: 10

---

## HTTP Endpoints

### SDK API (Base: `https://sdk.split.io/api`)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/splitChanges` | GET | Fetch feature flag definitions |
| `/segmentChanges/{name}` | GET | Fetch segment membership |

**Split Changes params:**
```
?since={changeNumber}     # required, -1 for initial
&sets={flagSets}          # optional, filter by flag sets
&till={changeNumber}      # optional, CDN bypass
&s={specVersion}          # optional, 1.1 or 1.3
```

**Segment Changes params:**
```
?since={changeNumber}     # required, -1 for initial
&till={changeNumber}      # optional, CDN bypass
```

### Auth API (Base: `https://auth.split.io/api`)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/auth` | GET | Get streaming auth token |

### Events API (Base: `https://events.split.io/api`)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/testImpressions/bulk` | POST | Submit impressions |
| `/testImpressions/count` | POST | Submit impression counts |
| `/events/bulk` | POST | Submit track events |
| `/keys/ss` | POST | Submit unique keys (none mode) |

---

## Data Types

### SplitDTO (Feature Flag)

```json
{
  "name": "my_feature",
  "trafficTypeName": "user",
  "killed": false,
  "status": "ACTIVE",
  "defaultTreatment": "off",
  "changeNumber": 1234567890,
  "algo": 2,
  "trafficAllocation": 100,
  "trafficAllocationSeed": 123,
  "seed": 456,
  "configurations": {
    "on": "{\"color\": \"blue\"}",
    "off": null
  },
  "sets": ["frontend", "mobile"],
  "impressionsDisabled": false,
  "prerequisites": [
    {"n": "other_feature", "ts": ["on", "enabled"]}
  ],
  "conditions": [...]
}
```

**Status values:** `ACTIVE` | `ARCHIVED`
**Algo values:** `1` = legacy hash, `2` = murmur3 (default)

**Prerequisites:** List of `{n: feature_flag_name, ts: required_treatments[]}`. All must pass for evaluation to proceed.

### Condition

```json
{
  "conditionType": "ROLLOUT",
  "matcherGroup": {
    "combiner": "AND",
    "matchers": [...]
  },
  "partitions": [
    {"treatment": "on", "size": 50},
    {"treatment": "off", "size": 50}
  ],
  "label": "in segment beta_users"
}
```

**Condition types:** `ROLLOUT` | `WHITELIST`

Note: Only `AND` combiner is supported. `WHITELIST` conditions bypass traffic allocation.

### Matcher

```json
{
  "matcherType": "IN_SEGMENT",
  "negate": false,
  "keySelector": {
    "trafficType": "user",
    "attribute": null
  },
  "userDefinedSegmentMatcherData": {
    "segmentName": "beta_users"
  }
}
```

### Matcher Types

| Type | Data Field | Description |
|------|------------|-------------|
| `ALL_KEYS` | - | Matches everything |
| `IN_SEGMENT` | `userDefinedSegmentMatcherData.segmentName` | Key in segment |
| `WHITELIST` | `whitelistMatcherData.whitelist[]` | Key in explicit list |
| `EQUAL_TO` | `unaryNumericMatcherData.{dataType,value}` | Numeric/datetime equality |
| `GREATER_THAN_OR_EQUAL_TO` | `unaryNumericMatcherData` | Numeric comparison |
| `LESS_THAN_OR_EQUAL_TO` | `unaryNumericMatcherData` | Numeric comparison |
| `BETWEEN` | `betweenMatcherData.{start,end,dataType}` | Numeric range |
| `EQUAL_TO_SET` | `whitelistMatcherData.whitelist[]` | Set equality |
| `CONTAINS_ANY_OF_SET` | `whitelistMatcherData.whitelist[]` | Set intersection > 0 |
| `CONTAINS_ALL_OF_SET` | `whitelistMatcherData.whitelist[]` | Attribute contains all |
| `PART_OF_SET` | `whitelistMatcherData.whitelist[]` | Attribute is subset |
| `STARTS_WITH` | `whitelistMatcherData.whitelist[]` | String prefix (any) |
| `ENDS_WITH` | `whitelistMatcherData.whitelist[]` | String suffix (any) |
| `CONTAINS_STRING` | `whitelistMatcherData.whitelist[]` | String contains (any) |
| `MATCHES_STRING` | `stringMatcherData.string` | Regex match |
| `EQUAL_TO_BOOLEAN` | `booleanMatcherData.value` | Boolean equality |
| `IN_SPLIT_TREATMENT` | `dependencyMatcherData.{split,treatments[]}` | Depends on another split |
| `EQUAL_TO_SEMVER` | `stringMatcherData.string` | Semver equality |
| `GREATER_THAN_OR_EQUAL_TO_SEMVER` | `stringMatcherData.string` | Semver comparison |
| `LESS_THAN_OR_EQUAL_TO_SEMVER` | `stringMatcherData.string` | Semver comparison |
| `BETWEEN_SEMVER` | `betweenStringMatcherData.{start,end}` | Semver range |
| `IN_LIST_SEMVER` | `whitelistMatcherData.whitelist[]` | Semver in list |
| `IN_LARGE_SEGMENT` | `userDefinedLargeSegmentMatcherData.largeSegmentName` | Key in large segment |
| `IN_RULE_BASED_SEGMENT` | `userDefinedSegmentMatcherData.segmentName` | Key matches rule-based segment |

**Data types for numeric matchers:** `NUMBER` | `DATETIME`

For `DATETIME`:
- Values are Java timestamps (milliseconds)
- `EQUAL_TO` zeroes hours/minutes/seconds
- `BETWEEN`/`GTOET`/`LTOET` zeroes only seconds

### SegmentChangesDTO

```json
{
  "name": "beta_users",
  "added": ["user1", "user2"],
  "removed": ["user3"],
  "since": 1234567890,
  "till": 1234567891
}
```

### Impression

```json
{
  "k": "user123",
  "t": "on",
  "m": 1234567890123,
  "c": 1234567890,
  "r": "in segment beta_users",
  "b": null,
  "pt": 1234567800000
}
```

| Field | Description |
|-------|-------------|
| `k` | Key name |
| `t` | Treatment |
| `m` | Timestamp (ms) |
| `c` | Change number |
| `r` | Rule label |
| `b` | Bucketing key (optional) |
| `pt` | Previous time - for deduplication (optional) |

### Bulk Impressions Format

```json
[
  {
    "f": "my_feature",
    "i": [
      {"k": "user1", "t": "on", "m": 123, "c": 456, "r": "label"},
      {"k": "user2", "t": "off", "m": 124, "c": 456, "r": "label"}
    ]
  }
]
```

### Impression Counts Format

```json
{
  "pf": [
    {"f": "my_feature", "m": 1234567800000, "rc": 150}
  ]
}
```

---

## Large Segments (Spec v1.2)

Large segments support millions of keys via Remote File Download (RFD) instead of incremental sync.

### Sync Protocol

```
1. Splits contain matcher: IN_LARGE_SEGMENT with largeSegmentName
2. SDK tracks referenced large segment names from splits

3. GET /largeSegmentDefinition/{name}?since={changeNumber}
   Response: LargeSegmentRFDResponseDTO
   
4. If notification_type == "LS_NEW_DEFINITION":
   - Download file from RFD.params.url using RFD.params.method
   - Parse as CSV (one key per line)
   - Replace entire segment with downloaded keys
   
5. If notification_type == "LS_EMPTY":
   - Clear segment (set to empty)
```

### LargeSegmentRFDResponseDTO

```json
{
  "n": "large_segment_name",     // name
  "t": "LS_NEW_DEFINITION",      // notification_type: LS_NEW_DEFINITION | LS_EMPTY
  "v": "1.0",                    // spec_version
  "cn": 1234567890,              // change_number
  "rfd": {                       // null if notification_type == LS_EMPTY
    "d": {                       // data
      "f": 1,                    // format: 1=CSV
      "k": 1000000,              // total_keys
      "s": 52428800,             // file_size (bytes)
      "e": 1234567890123         // expires_at (ms timestamp)
    },
    "p": {                       // params
      "m": "GET",                // method
      "u": "https://...",        // url (pre-signed S3 URL)
      "h": {},                   // headers
      "b": null                  // body
    }
  }
}
```

### CSV File Format (v1.0)

- One key per line
- No header row
- Single column
- UTF-8 encoding

**Edge case handling:**
- Empty lines: skip
- Whitespace: trim leading/trailing
- BOM markers: strip UTF-8 BOM (`0xEF 0xBB 0xBF`) if present
- Lines with commas: treat as malformed, skip line and log warning

### Storage Interface

```
LargeSegmentStorage:
  Update(name, keys[], changeNumber)      // full replace
  ChangeNumber(name) → int64              // -1 if not cached
  IsInLargeSegment(name, key) → bool      // membership test
  LargeSegmentsForUser(key) → []string    // all containing segments
  Count() → int                           // number of segments
  TotalKeys(name) → int                   // keys in segment
```

### SSE Notification

Type: `LS_DEFINITION_UPDATE`

```json
{
  "ls": [                        // array of LargeSegmentRFDResponseDTO
    { "n": "segment1", "t": "LS_NEW_DEFINITION", ... }
  ]
}
```

### Concurrency

- Max 5 concurrent large segment downloads
- Sync uses semaphore for rate limiting

---

## Rule-Based Segments (Spec v1.3)

Dynamic segments defined by conditions rather than explicit key lists.

### RuleBasedSegmentDTO

```json
{
  "changeNumber": 1234567890,
  "name": "high_value_users",
  "status": "ACTIVE",            // ACTIVE | ARCHIVED
  "trafficTypeName": "user",
  "excluded": {
    "keys": ["user1", "user2"],  // explicitly excluded keys
    "segments": [                 // excluded via segment membership
      {"name": "segment1", "type": "standard"},      // standard segment
      {"name": "segment2", "type": "rule-based"},    // nested rule-based
      {"name": "segment3", "type": "large"}          // large segment
    ]
  },
  "conditions": [                 // evaluated in order, first match wins
    {
      "conditionType": "ROLLOUT",
      "matcherGroup": { ... }     // same structure as split conditions
    }
  ]
}
```

### Evaluation Algorithm

```
MAX_RECURSION_DEPTH = 10

evaluate_rule_based_segment(name, key, attributes, bucketing_key, depth=0):
  if depth >= MAX_RECURSION_DEPTH:
    log_error("Rule-based segment recursion depth exceeded")
    return false
  
  rbs = storage.get_rule_based_segment(name)
  
  if rbs is nil:
    return false
  
  # Check explicit exclusions
  if key in rbs.excluded.keys:
    return false
  
  # Check segment-based exclusions
  for excluded_segment in rbs.excluded.segments:
    if excluded_segment.type == "standard":
      if key in standard_segment(excluded_segment.name):
        return false
    elif excluded_segment.type == "rule-based":
      if evaluate_rule_based_segment(excluded_segment.name, key, attributes, bucketing_key, depth + 1):
        return false
    elif excluded_segment.type == "large":
      if key in large_segment(excluded_segment.name):
        return false
  
  # Evaluate conditions (first match wins)
  for condition in rbs.conditions:
    if matches(condition.matcher_group, key, attributes, bucketing_key):
      return true
  
  return false
```

**Recursion limit:** Max depth of 10 for nested rule-based segment evaluation. Exceeding returns `false` and logs error.

### Sync Protocol

Rule-based segments sync alongside splits:

```
GET /splitChanges?since={changeNumber}&s=1.3
Response includes:
{
  "splits": [...],
  "ruleBasedSegments": {
    "d": [...],                  // array of RuleBasedSegmentDTO
    "t": 1234567890,             // till (change number)
    "s": 1234567880              // since (change number)
  }
}
```

### SSE Notification

Type: `RB_SEGMENT_UPDATE`

Uses same `SplitChangeUpdate` structure with `ruleBasedSegment` field instead of `featureFlag`.

Supports optimistic updates with `pcn` (previous change number).

### Storage Interface

```
RuleBasedSegmentStorage:
  Update(toAdd[], toRemove[], till)
  ReplaceAll(segments[], changeNumber)
  GetRuleBasedSegmentByName(name) → RuleBasedSegmentDTO
  RuleBasedSegmentNames() → []string
  ChangeNumber() → int64
  Contains(names[]) → bool
  Segments() → Set[string]                    // referenced standard segments
  LargeSegments() → Set[string]               // referenced large segments
```

---

## Evaluation Algorithm

```
evaluate(key, bucketing_key, split_name, attributes):
  split = storage.get(split_name)
  
  if split is nil:
    return {treatment: "control", label: "definition not found"}
  
  if split.killed:
    return {treatment: split.default_treatment, label: "killed"}
  
  # Check prerequisites before any conditions
  if split.prerequisites:
    if !check_prerequisites(split.prerequisites, key, bucketing_key, attributes):
      return {treatment: split.default_treatment, label: "prerequisites not met"}
  
  bucketing_key = bucketing_key || key
  in_rollout = false
  
  for condition in split.conditions:
    # Traffic allocation check - ONLY on first ROLLOUT condition
    if !in_rollout && condition.type == "ROLLOUT":
      if split.traffic_allocation < 100:
        bucket = calculate_bucket(bucketing_key, split.traffic_allocation_seed, split.algo)
        if bucket > split.traffic_allocation:
          return {treatment: split.default_treatment, label: "not in split"}
        in_rollout = true
    
    if matches(condition.matcher_group, key, attributes):
      bucket = calculate_bucket(bucketing_key, split.seed, split.algo)
      treatment = select_treatment(condition.partitions, bucket)
      return {treatment: treatment, label: condition.label}
  
  return {treatment: split.default_treatment, label: "default rule"}

check_prerequisites(prerequisites, key, bucketing_key, attributes):
  for prereq in prerequisites:
    result = evaluate(key, bucketing_key, prereq.feature_flag_name, attributes)
    if result.treatment not in prereq.treatments:
      return false
  return true
```

**Prerequisites:** Evaluated before any conditions. ALL prerequisites must pass (treatment must be in allowed list). Failure returns `default_treatment` with label `"prerequisites not met"`.

### Bucketing (Treatment Selection)

```
calculate_bucket(key, seed, algo):
  if algo == 2:  # murmur3
    hash = murmur3_32(key, seed)
  else:          # legacy
    hash = legacy_hash(key, seed)
  
  return abs(hash % 100) + 1   # Bucket: 1-100

select_treatment(partitions, bucket):
  accumulated = 0
  for partition in partitions:
    accumulated += partition.size
    if bucket <= accumulated:
      return partition.treatment
  
  return last_partition.treatment
```

**Hash functions:**

Murmur3: `murmur3_32(key_bytes, seed_as_u32)`

Legacy (Java-style):
```
legacy_hash(key, seed):
  h = 0
  for char in key:
    h = 31 * h + char_code
  return h ^ seed
```

### Matcher Evaluation

```
matches(matcher_group, key, attributes):
  results = []
  for matcher in matcher_group.matchers:
    result = evaluate_matcher(matcher, key, attributes)
    if matcher.negate:
      result = !result
    results.append(result)
  
  # Only AND is supported
  return all(results)

evaluate_matcher(matcher, key, attributes):
  matching_value = get_matching_value(matcher, key, attributes)
  if matching_value is error:
    return false  # Missing attribute = no match
  
  # Type-specific matching logic...
```

### Attribute Handling

- If `matcher.key_selector.attribute` is nil → use `key`
- If attribute specified but missing → return `false` (log warning)
- If wrong type → return `false` (log error)
- Boolean matcher: coerces string via `parse_bool(lowercase(value))`

### Dependency Matcher (IN_SPLIT_TREATMENT)

Evaluates another split and checks if result is in expected treatments list.

**Warning:** No cycle detection. Cycles cause stack overflow. Backend must validate.

---

## Impression Management

### Modes

| Mode | Full Impressions | Counts | Unique Keys | Deduplication |
|------|------------------|--------|-------------|---------------|
| `optimized` | First per hour + with properties | Yes (deduped) | No | Hash + 1hr window |
| `debug` | All | No | No | None |
| `none` | None | Yes (all) | Yes | N/A |

### Deduplication (Optimized Mode)

**Hash key:** `{key}:{split}:{treatment}:{label}:{change_number}`
**Hash function:** Murmur3-128, take 64 LSBs
**Cache:** LRU cache mapping hash → timestamp (max 500,000 entries)

**Logic:**
```
previous_time = cache.test_and_set(hash, current_time)
impression.pt = previous_time

if previous_time == 0:  # First time ever
  send impression
elif previous_time < truncate_to_hour(current_time):  # First in current hour
  send impression
else:  # Duplicate within same hour
  increment counter for (split, hour)
  don't send impression
```

**Hour truncation:**
```
truncate_to_hour(timestamp_ms) = timestamp_ms - (timestamp_ms % 3600000)
```

### Impression Listener

All modes support an optional listener callback that receives ALL impressions (including deduped).

### Queue & Flush

**Queue limits:**
- Queue size: 10,000 impressions (configurable)
- Bulk size: 5,000 per API call (configurable)

**Flush triggers:**
1. Periodic timer fires (default: 300s / 5 minutes)
2. Queue reaches bulk size threshold
3. SDK `destroy()` called

**Queue overflow:**
- When queue reaches `impressions_queue_size` limit
- New impressions are dropped (not queued)
- Increment telemetry counter for dropped impressions
- Log warning

### Bulk Impressions Endpoint

`POST https://events.split.io/api/testImpressions/bulk`

**Request body:**
```json
[
  {
    "f": "feature_name",
    "i": [
      {
        "k": "user_key",
        "t": "on",
        "m": 1234567890123,
        "c": 1234567890,
        "r": "in segment beta_users",
        "b": "org456",
        "pt": 1234567800000
      }
    ]
  }
]
```

| Field | Type | Description |
|-------|------|-------------|
| `f` | string | Feature flag name |
| `i` | array | Impressions for this feature |
| `k` | string | Matching key |
| `t` | string | Treatment returned |
| `m` | int64 | Timestamp (milliseconds) |
| `c` | int64 | Split change number at evaluation time |
| `r` | string | Label (rule that matched) |
| `b` | string? | Bucketing key (omit if same as `k`) |
| `pt` | int64? | Previous time seen (null if first impression) |

**Request headers:**
```
Authorization: Bearer {api_key}
Content-Type: application/json
SplitSDKVersion: {sdk_name}-{version}
SplitSDKMachineIP: {ip_address}
SplitSDKMachineName: {hostname}
```

**Response:** `200 OK` (empty body)

### Impression Counts Endpoint

`POST https://events.split.io/api/testImpressions/count`

Used in OPTIMIZED and NONE modes to report total evaluation counts (including deduplicated impressions).

**Request body:**
```json
{
  "pf": [
    {"f": "feature_name", "m": 1234567800000, "rc": 150},
    {"f": "another_feature", "m": 1234567800000, "rc": 42}
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `pf` | array | Per-feature counts |
| `f` | string | Feature flag name |
| `m` | int64 | Hour timestamp (truncated to hour boundary) |
| `rc` | int | Raw count of evaluations in that hour |

**Hour truncation:** `timestamp_ms - (timestamp_ms % 3600000)`

**Flush triggers:** Same as impressions (timer, bulk size, destroy)

### Unique Keys Endpoint (NONE mode only)

`POST https://events.split.io/api/keys/ss`

In NONE mode, track which keys were evaluated (without full impressions).

**Request body:**
```json
{
  "keys": [
    {"f": "feature_name", "ks": ["user1", "user2", "user3"]}
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `keys` | array | Per-feature key sets |
| `f` | string | Feature flag name |
| `ks` | array | Unique keys evaluated for this feature |

---

## Events (Track API)

```
track(key, traffic_type, event_type, value, properties):
  event = {
    key: key,
    trafficTypeName: traffic_type,
    eventTypeId: event_type,
    value: value,           # optional float
    properties: properties, # optional map
    timestamp: now_ms
  }
  queue.push(event)
```

**Limits:**
- Queue size: 10,000 events (configurable)
- Properties: max 32,768 bytes (32KB) when serialized
- Property count: max 300 properties

---

## Readiness

SDK must signal when ready for evaluations.

**Ready conditions:**
1. Initial sync complete (all splits + referenced segments fetched)
2. For streaming: SSE connection established (or fallback to polling complete)

**API:**
- `block_until_ready(timeout_ms)` - synchronous wait
- `is_ready()` - polling check

### SDK Events

Register callbacks for SDK lifecycle events:

```
client.on(event, callback)
```

| Event | Description |
|-------|-------------|
| `SDK_READY` | SDK initialized and ready for evaluations (fires once) |
| `SDK_UPDATE` | Feature flag or segment changed (fires multiple times) |

**SDK_UPDATE triggers:**
- Feature flag updated
- Feature flag killed
- Segment membership changed
- Rule-based segment updated

---

## Client API

```
# Core evaluation
treatment = client.get_treatment(key, split_name, attributes, evaluation_options)
{treatment, config} = client.get_treatment_with_config(key, split_name, attributes, evaluation_options)

# Bulk evaluation  
treatments = client.get_treatments(key, split_names, attributes, evaluation_options)
treatments_with_config = client.get_treatments_with_config(key, split_names, attributes, evaluation_options)

# By flag sets
treatments = client.get_treatments_by_flag_set(key, flag_set, attributes, evaluation_options)
treatments = client.get_treatments_by_flag_sets(key, flag_sets, attributes, evaluation_options)
treatments_with_config = client.get_treatments_with_config_by_flag_set(key, flag_set, attributes, evaluation_options)
treatments_with_config = client.get_treatments_with_config_by_flag_sets(key, flag_sets, attributes, evaluation_options)

# Event tracking
client.track(key, traffic_type, event_type, value, properties)

# SDK events
client.on(event, callback)

# Lifecycle
client.block_until_ready(timeout_ms)
client.destroy()
```

### Evaluation Options

Optional parameter for additional control over treatment evaluation:

```
evaluation_options = {
  properties: {}  # Properties to attach to generated impressions
}
```

Impression properties are sent to Split backend for analytics.

## Manager API

```
splits = manager.splits()           # all split views
split = manager.split(name)         # single split view  
names = manager.split_names()       # just names
```

**SplitView:**
```
{
  name: "my_feature",
  traffic_type: "user",
  killed: false,
  treatments: ["on", "off"],
  change_number: 123,
  configs: {"on": "{...}", "off": null},
  sets: ["frontend"],
  default_treatment: "off",
  impressions_disabled: false,
  prerequisites: [{"feature": "other_flag", "treatments": ["on"]}]
}
```

---

## Configuration

```
{
  # Required
  api_key: "sdk-key-xxx",
  
  # Operation mode
  operation_mode: :in_memory_standalone,
  
  # Sync settings
  streaming_enabled: true,
  splits_refresh_rate: 60,          # seconds
  segments_refresh_rate: 60,        # seconds
  
  # Impression settings  
  impressions_mode: :optimized,
  impressions_refresh_rate: 300,    # seconds
  impressions_queue_size: 10000,
  impressions_bulk_size: 5000,
  labels_enabled: true,
  
  # Event settings
  events_queue_size: 10000,
  events_bulk_size: 5000,
  events_refresh_rate: 60,          # seconds
  
  # Connection settings
  connection_timeout: 10000,        # ms
  read_timeout: 60000,              # ms
  
  # URLs (override for proxy/self-hosted)
  sdk_url: "https://sdk.split.io/api",
  events_url: "https://events.split.io/api",
  auth_url: "https://auth.split.io/api",
  streaming_url: "https://streaming.split.io",
  telemetry_url: "https://telemetry.split.io/api",
  
  # Localhost mode
  split_file: "path/to/splits.yaml",
  localhost_refresh_enabled: false,
  
  # Telemetry & sampling
  telemetry_refresh_rate: 3600,     # seconds (1 hour)
  data_sampling: 1.0,               # 0.1 to 1.0
  
  # Flag sets filter (optional)
  flag_sets_filter: ["frontend"],   # only sync flags in these sets
  
  # IP/Machine metadata
  ip_addresses_enabled: true
}
```

---

## Localhost Mode

For development without Split backend.

### File Formats

| Extension | Format |
|-----------|--------|
| `.yaml`, `.yml` | YAML (recommended) |
| `.json` | Full JSON (same as API response) |
| `.split` | Legacy (deprecated) |

### YAML Format

```yaml
# Simple - all keys get this treatment
- my_feature:
    treatment: "on"

# With config
- another_feature:
    treatment: "off"
    config: '{"color": "red"}'

# Whitelist - only specific keys
- complex_feature:
    treatment: "v2"
    keys:
      - user1
      - user2
    config: '{"version": 2}'

# Single key can be string
- single_user_feature:
    treatment: "beta"
    keys: "special_user"
```

**Multiple conditions per split:**
```yaml
# First entry: whitelist (checked first)
- my_feature:
    treatment: "vip"
    keys:
      - admin
      - premium_user

# Second entry: rollout (checked second)
- my_feature:
    treatment: "standard"
```

### JSON Format

Full API format - same as `/splitChanges` response:

```json
{
  "ff": {
    "s": -1,
    "t": 1660326991072,
    "d": [
      {
        "name": "split_1",
        "trafficTypeName": "user",
        "trafficAllocation": 100,
        "trafficAllocationSeed": -1364119282,
        "seed": -605938843,
        "status": "ACTIVE",
        "killed": false,
        "defaultTreatment": "off",
        "changeNumber": 1660326991072,
        "algo": 2,
        "configurations": {},
        "conditions": [...]
      }
    ]
  }
}
```

### Segments in Localhost

Place segment files in a directory:
```
segments/
  beta_users.json
  employees.json
```

Segment file format:
```json
{
  "name": "beta_users",
  "added": ["user1", "user2"],
  "removed": [],
  "since": -1,
  "till": 1489542661161
}
```

### Change Detection

**No filesystem watcher.** Uses SHA1 hash comparison on periodic fetch:
- If file content hash changed → increment internal changeNumber
- Configurable refresh period (same as splits_refresh_rate)

### Sanitization

Invalid localhost file values are auto-corrected:

| Field | Sanitization |
|-------|--------------|
| `trafficAllocation` | Clamp to 0-100, default 100 |
| `trafficAllocationSeed` | Generate random if 0 |
| `seed` | Generate random if 0 |
| `status` | Default to "ACTIVE" |
| `defaultTreatment` | Default to "control" |
| `algo` | Force to 2 (murmur3) |
| `conditions` | Add ALL_KEYS rollout if empty |

---

## Input Validation

### Flag Set Names

Strict validation (rejected if invalid):
- Regex: `^[a-z0-9][_a-z0-9]{0,49}$`
- Must start with letter or number
- Lowercase alphanumeric + underscore only
- Max 50 characters
- Whitespace trimmed, uppercase auto-lowercased

### Attribute Type Checking

Runtime validation during matcher evaluation:

| Matcher Type | Expected Type | On Mismatch |
|--------------|---------------|-------------|
| Numeric | `int64` or `int` | Log error, return `false` |
| String | `string` | Log error, return `false` |
| Boolean | `bool` or parseable string | Log error, return `false` |
| Set | `[]string` | Log error, return `false` |

Missing required attribute → log warning, return `false`.

### Event Limits

| Limit | Value |
|-------|-------|
| Max event size | 32 KB |
| Max batch size | 5 MB |

### Error Handling Strategy

**Silent degradation with logging** - never throws/panics:

| Scenario | Response | Label |
|----------|----------|-------|
| Split not found | Return `"control"` | `"definition not found"` |
| Split killed | Return `defaultTreatment` | `"killed"` |
| Traffic excluded | Return `defaultTreatment` | `"not in split"` |
| No condition matched | Return `defaultTreatment` | `"default rule"` |
| Unsupported matcher | Return `"control"` | `"targeting rule type unsupported by sdk"` |
| Prerequisites not met | Return `defaultTreatment` | `"prerequisites not met"` |

---

## Impression Labels

| Label | Meaning |
|-------|---------|
| `definition not found` | Split doesn't exist in storage |
| `killed` | Split is killed |
| `not in split` | Excluded by traffic allocation |
| `default rule` | No condition matched |
| `in segment {name}` | Matched segment condition |
| `whitelisted` | Matched whitelist condition |
| `targeting rule type unsupported by sdk` | Matcher not implemented |
| `prerequisites not met` | Prerequisite split check failed |
| `{custom label}` | Condition's configured label |

---

## Streaming Protocol (SSE/Ably)

### Auth Token

**Request:** `GET /api/v2/auth`

**Response:**
```json
{
  "token": "<JWT>",
  "pushEnabled": true
}
```

**JWT Payload:**
```json
{
  "x-ably-capability": "{\"channel_name\": [\"subscribe\"]}",
  "exp": 1612900000,
  "iat": 1612896400
}
```

### Channel Types

| Channel Pattern | Purpose |
|-----------------|---------|
| `{base64_org}_{base64_env}_splits` | Feature flag updates |
| `{base64_org}_{base64_env}_segments` | Segment updates |
| `control_pri` | Primary control channel |
| `control_sec` | Secondary control channel |

### Channel Capabilities

| Capability | Meaning |
|------------|---------|
| `subscribe` | Can receive messages |
| `channel-metadata:publishers` | Can receive occupancy metrics |

Control channels have both capabilities; data channels have only `subscribe`.

### SSE Connection

```
GET {streaming_url}/event-stream?channels={channels}&accessToken={token}&v=1.1

Headers:
  Accept: text/event-stream
  Content-Type: text/event-stream
  Cache-Control: no-cache
```

**Channels param:** Comma-separated. Control channels prefixed with `[?occupancy=metrics.publishers]`.

### SSE Message Format

```
id: <event-id>
event: message
data: {"id":"...","timestamp":123,"channel":"...","data":"{...}"}

```

The outer `data` field contains JSON with a nested `data` string that must be parsed separately.

### Message Types

| Type | Purpose | Fields |
|------|---------|--------|
| `SPLIT_UPDATE` | Flag changed | `changeNumber`, `pcn`, `c`, `d` |
| `SPLIT_KILL` | Flag killed | `changeNumber`, `splitName`, `defaultTreatment` |
| `SEGMENT_UPDATE` | Segment changed | `changeNumber`, `segmentName` |
| `CONTROL` | Streaming control | `controlType` |

**Control types:** `STREAMING_ENABLED`, `STREAMING_PAUSED`, `STREAMING_DISABLED`

### Optimistic Updates

For `SPLIT_UPDATE`:
- `pcn` = previous change number
- `c` = compression (0=none, 1=gzip, 2=zlib)
- `d` = base64-encoded (optionally compressed) SplitDTO JSON

If local changeNumber == `pcn`, apply `d` directly without HTTP fetch.

### Occupancy

Ably sends `[meta]occupancy` events on control channels:
```json
{"metrics": {"publishers": 2}}
```

If all control channels have 0 publishers → fall back to polling.

### Token Refresh

- Refresh at: `token_lifetime - 10 minutes`
- On refresh: re-authenticate via `/api/v2/auth`

### Keepalive

- Timeout: 70 seconds without any data
- Ably sends `:keepalive` comment lines
- On timeout: reconnect with backoff

### Ably Errors

Retryable error codes: 40140-40149 (token-related).
Other errors → permanent polling fallback.

---

## Telemetry

### Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/metrics/config` | POST | SDK initialization config |
| `/metrics/usage` | POST | Runtime stats |

Base URL: `https://telemetry.split.io/api/v1`

### Config Telemetry (sent once at init)

```json
{
  "oM": 0,        // OperationMode: 0=standalone, 1=consumer
  "sE": true,     // StreamingEnabled
  "st": "memory", // Storage type
  "iM": 0,        // ImpressionsMode: 0=optimized, 1=debug, 2=none
  "iL": false,    // ImpressionsListenerEnabled
  "tR": 1234,     // TimeUntilReady (ms)
  "rR": {         // Refresh rates (seconds)
    "sp": 60,     // Splits
    "se": 60,     // Segments
    "im": 300,    // Impressions
    "ev": 60,     // Events
    "te": 3600    // Telemetry
  },
  "uO": {         // URL overrides (bool flags)
    "s": false,   // SDK URL
    "e": false,   // Events URL
    "a": false,   // Auth URL
    "st": false,  // Streaming URL
    "t": false    // Telemetry URL
  }
}
```

### Runtime Stats (sent periodically)

```json
{
  "mL": {},       // MethodLatencies (histogram buckets per method)
  "mE": {},       // MethodExceptions (count per method)
  "hL": {},       // HTTPLatencies (per resource)
  "hE": {},       // HTTPErrors (per resource, by status code)
  "iQ": 1000,     // ImpressionsQueued
  "iDe": 500,     // ImpressionsDeduped
  "iDr": 0,       // ImpressionsDropped
  "eQ": 200,      // EventsQueued
  "eD": 0,        // EventsDropped
  "spC": 50,      // SplitCount
  "seC": 10,      // SegmentCount
  "sL": 3600000,  // SessionLengthMs
  "sE": [],       // StreamingEvents (max 20)
  "t": []         // Tags (max 10)
}
```

### Latency Buckets

23 exponential buckets (ms):
```
1.00, 1.50, 2.25, 3.38, 5.06, 7.59, 11.39, 17.09, 25.63, 38.44,
57.67, 86.50, 129.75, 194.62, 291.93, 437.89, 656.84, 985.26,
1477.89, 2216.84, 3325.26, 4987.89, 7481.83
```

### Methods Tracked

- `treatment`, `treatments`
- `treatmentWithConfig`, `treatmentsWithConfig`
- `treatmentsByFlagSet`, `treatmentsByFlagSets`
- `treatmentsWithConfigByFlagSet`, `treatmentsWithConfigByFlagSets`
- `track`

### Resources Tracked

- `splits`, `segments` (sync)
- `impressions`, `impressionsCount`, `events` (recording)
- `telemetry`, `token` (meta)

### Streaming Events Tracked

| Event | Description |
|-------|-------------|
| SSE connection established | Stream connected |
| Occupancy (pri/sec) | Publisher count changed |
| Streaming status | Mode changed |
| Connection error | SSE failed |
| Token refresh | New token fetched |
| Ably error | Ably returned error |
| Sync mode | Streaming/polling switch |

---

## HTTP Headers

### Standard Headers (all requests)

| Header | Value |
|--------|-------|
| `Authorization` | `Bearer {api_key}` |
| `Content-Type` | `application/json` |
| `Accept-Encoding` | `gzip` |
| `SplitSDKVersion` | `{language}-{name}-{version}` (e.g., `go-client-1.0.0`) |
| `SplitSDKMachineIP` | IP address (omit if "NA" or "unknown") |
| `SplitSDKMachineName` | Hostname (omit if "NA" or "unknown") |

### Conditional Headers

| Header | When |
|--------|------|
| `SplitSDKImpressionsMode` | POST to `/testImpressions/bulk` |
| `SplitSDKClientKey` | Consumer mode / SSE connections |
| `Cache-Control` | CDN bypass requests |

### Metadata DTO

Sent with impressions/events in request body:

```json
{
  "s": "go-client-1.0.0",  // SDKVersion
  "i": "192.168.1.1",      // MachineIP
  "n": "hostname"          // MachineName
}
```

---

## Redis Storage Schema

### Key Patterns

All keys prefixed with `SPLITIO.` (configurable prefix prepended).

| Pattern | Type | Description |
|---------|------|-------------|
| `SPLITIO.split.{name}` | STRING | Feature flag JSON |
| `SPLITIO.splits.till` | STRING | Change number |
| `SPLITIO.segment.{name}` | SET | Segment member keys |
| `SPLITIO.segment.{name}.till` | STRING | Segment change number |
| `SPLITIO.flagSet.{set}` | SET | Flag names in set |
| `SPLITIO.impressions` | LIST | Impression queue |
| `SPLITIO.impressions.count` | HASH | Impression counts |
| `SPLITIO.events` | LIST | Event queue |
| `SPLITIO.uniquekeys` | LIST | Unique keys (none mode) |
| `SPLITIO.telemetry.init` | HASH | SDK init telemetry |
| `SPLITIO.hash` | STRING | API key hash |

### TTLs

| Key | TTL |
|-----|-----|
| `SPLITIO.impressions` | 1 hour |
| `SPLITIO.impressions.count` | 1 hour |
| `SPLITIO.uniquekeys` | 1 hour |
| Split/segment data | None (persistent) |

### Custom Prefix

Keys become: `{prefix}.SPLITIO.{key}`

Example with prefix `myapp`: `myapp.SPLITIO.split.my_feature`

### Cluster Mode

Keys prefixed with hashtag for slot routing: `{SPLITIO}myapp.SPLITIO.split.my_feature`

### Data Formats

**Impression queue element:**
```json
{
  "m": {"s": "go-1.0.0", "i": "192.168.1.1", "n": "host"},
  "i": {"k": "user", "f": "feature", "t": "on", "r": "label", "c": 123, "m": 456}
}
```

**Impression count hash field:** `{featureName}::{timeframe}` → count

**Segment:** SET of user keys (plain strings)

---

## Spec Versions

| Version | Features |
|---------|----------|
| `1.0` | Default - core feature flags and segments |
| `1.1` | Semver matchers |
| `1.2` | Large segments (IN_LARGE_SEGMENT) |
| `1.3` | Rule-based segments (IN_RULE_BASED_SEGMENT) |

SDK sends spec version in `SplitVersionFilter` header to indicate supported features.

---

## Elixir Implementation Architecture

### Design Principles

1. **Struct-first**: All domain data represented as typed structs with `@enforce_keys`, `@type t`, and pattern matching
2. **OTP-native**: Leverage supervision trees, GenServers, and ETS for reliability
3. **Concurrent by default**: Parallel segment fetching, non-blocking evaluations
4. **Fault-tolerant**: Isolate failures, auto-recover with backoff
5. **Zero-copy evaluations**: ETS for read-heavy storage, no process bottlenecks
6. **Parse, don't validate**: Convert JSON to structs at API boundary, work with typed data internally
7. **Backend-agnostic storage**: Pluggable storage backends (ETS single-node, ETS clustered, Redis future)

### Storage Backend Architecture

The SDK supports multiple storage backends via a behaviour-based abstraction. Storage modules are **stateless wrappers** that read/write to the configured backend directly (no GenServer bottleneck for reads).

#### Supported Backends

| Backend | Mode | Use Case |
|---------|------|----------|
| `Splitio.Storage.Backend.ETS` | Single node | Development, simple deployments |
| `Splitio.Storage.Backend.Cluster` | Multi-node ETS | Distributed Elixir clusters |
| `Splitio.Storage.Backend.Redis` | External Redis | Shared state across non-clustered nodes (future) |

#### Backend Behaviour

```elixir
defmodule Splitio.Storage.Backend do
  @moduledoc "Storage backend behaviour"

  @type split_name :: String.t()
  @type segment_name :: String.t()
  @type change_number :: integer()

  # Splits
  @callback get_split(split_name()) :: {:ok, Split.t()} | :not_found
  @callback get_splits() :: [Split.t()]
  @callback put_split(Split.t()) :: :ok
  @callback delete_split(split_name()) :: :ok
  @callback get_splits_change_number() :: change_number()
  @callback set_splits_change_number(change_number()) :: :ok

  # Segments
  @callback get_segment(segment_name()) :: {:ok, Segment.t()} | :not_found
  @callback put_segment(Segment.t()) :: :ok
  @callback segment_contains?(segment_name(), key :: String.t()) :: boolean()

  # Large Segments
  @callback large_segment_contains?(segment_name(), key :: String.t()) :: boolean()
  @callback put_large_segment_keys(segment_name(), keys :: MapSet.t()) :: :ok

  # Rule-Based Segments
  @callback get_rule_based_segment(segment_name()) :: {:ok, RuleBasedSegment.t()} | :not_found
  @callback put_rule_based_segment(RuleBasedSegment.t()) :: :ok
end
```

#### Storage Facade

The `Splitio.Storage` module routes to the configured backend:

```elixir
defmodule Splitio.Storage do
  @moduledoc "Storage facade - routes to configured backend"

  def get_split(name) do
    backend().get_split(name)
  end

  def put_split(split) do
    backend().put_split(split)
  end

  defp backend do
    Application.get_env(:splitio, :storage_backend, Splitio.Storage.Backend.ETS)
  end
end
```

#### ETS Backend (Single Node)

Simple, fast, no coordination:

```elixir
defmodule Splitio.Storage.Backend.ETS do
  @behaviour Splitio.Storage.Backend

  # Tables created at application start:
  # - :splitio_splits (set, public, read_concurrency: true)
  # - :splitio_segments (set, public, read_concurrency: true)
  # - :splitio_large_segments (set, public, read_concurrency: true)
  # - :splitio_rule_based_segments (set, public, read_concurrency: true)
  # - :splitio_metadata (set, public) - stores change numbers

  @impl true
  def get_split(name) do
    case :ets.lookup(:splitio_splits, name) do
      [{^name, split}] -> {:ok, split}
      [] -> :not_found
    end
  end

  @impl true
  def put_split(split) do
    :ets.insert(:splitio_splits, {split.name, split})
    :ok
  end

  # ... etc
end
```

#### Clustered ETS Backend

For distributed Elixir deployments. Uses leader election to designate one node as the sync coordinator.

##### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Erlang Cluster                           │
│                   (via libcluster)                          │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐         ┌──────────┐         ┌──────────┐
   │  Node A  │         │  Node B  │         │  Node C  │
   │ (LEADER) │         │ follower │         │ follower │
   ├──────────┤         ├──────────┤         ├──────────┤
   │ ETS tbls │────────▶│ ETS tbls │         │ ETS tbls │
   │ Sync ✓   │────────▶│ Sync ✗   │         │ Sync ✗   │
   └──────────┘         └──────────┘         └──────────┘
         │                    ▲                    ▲
         │                    │                    │
         └────────────────────┴────────────────────┘
                    Replication (deltas)
```

##### Design Decisions

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Leader election | `:global` | Built-in, simple, sufficient for this use case |
| Node discovery | `libcluster` | Standard for Elixir clustering |
| Replication transport | Erlang distribution | GenServer calls between nodes |
| Consistency model | Eventual | Feature flags tolerate brief staleness |
| Split brain | Accept stale data | Minority partition serves cached data |
| Follower join | Full state dump | Guarantees consistent starting point |

##### Leader Election

```elixir
defmodule Splitio.Cluster.Leader do
  @moduledoc "Leader election using :global"
  use GenServer

  @leader_name {:global, __MODULE__}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @leader_name)
  end

  def leader?() do
    case :global.whereis_name(__MODULE__) do
      pid when is_pid(pid) -> pid == self()
      :undefined -> false
    end
  end

  def leader_node() do
    case :global.whereis_name(__MODULE__) do
      pid when is_pid(pid) -> node(pid)
      :undefined -> nil
    end
  end
end
```

##### Cluster Membership

```elixir
defmodule Splitio.Cluster.Membership do
  @moduledoc "Cluster membership tracking via :pg"
  use GenServer

  @group :splitio_nodes

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    :pg.start_link()
    :pg.join(@group, self())
    {:ok, %{}}
  end

  def members() do
    :pg.get_members(@group)
  end
end
```

##### Replication Flow

**On write (leader only):**
1. Leader writes to local ETS
2. Leader broadcasts delta to all followers via GenServer.cast
3. Followers apply delta to local ETS

**On follower join:**
1. New node starts, joins `:pg` group
2. New node requests full state from leader: `GenServer.call(leader_pid, :get_full_state)`
3. Leader serializes all ETS tables, sends to follower
4. Follower populates local ETS tables
5. Follower begins receiving deltas

**On leader failover:**
1. `:global` detects leader process died
2. Another node's `Splitio.Cluster.Leader` process registers as new leader
3. New leader starts sync processes (was previously not syncing)
4. Followers continue with cached data, receive updates once new leader syncs

##### Replicator Implementation

```elixir
defmodule Splitio.Cluster.Replicator do
  @moduledoc "Handles state replication between cluster nodes"
  use GenServer

  # Called by storage backend after local write
  def broadcast_delta(delta) do
    if Splitio.Cluster.Leader.leader?() do
      for pid <- Splitio.Cluster.Membership.members(), pid != self() do
        GenServer.cast(pid, {:apply_delta, delta})
      end
    end
  end

  # Called when a new follower joins
  def request_full_state() do
    leader_pid = :global.whereis_name(Splitio.Cluster.Leader)
    GenServer.call(leader_pid, :get_full_state, :timer.minutes(5))
  end

  def handle_call(:get_full_state, _from, state) do
    full_state = %{
      splits: :ets.tab2list(:splitio_splits),
      segments: :ets.tab2list(:splitio_segments),
      large_segments: :ets.tab2list(:splitio_large_segments),
      rule_based_segments: :ets.tab2list(:splitio_rule_based_segments),
      metadata: :ets.tab2list(:splitio_metadata)
    }
    {:reply, full_state, state}
  end

  def handle_cast({:apply_delta, delta}, state) do
    apply_delta(delta)
    {:noreply, state}
  end

  defp apply_delta({:put_split, split}) do
    :ets.insert(:splitio_splits, {split.name, split})
  end

  defp apply_delta({:delete_split, name}) do
    :ets.delete(:splitio_splits, name)
  end

  # ... other delta types
end
```

##### Delta Types

```elixir
@type delta ::
  {:put_split, Split.t()}
  | {:delete_split, String.t()}
  | {:put_segment, Segment.t()}
  | {:update_segment, String.t(), added :: [String.t()], removed :: [String.t()]}
  | {:put_large_segment, String.t(), MapSet.t()}
  | {:put_rule_based_segment, RuleBasedSegment.t()}
  | {:set_change_number, table :: atom(), integer()}
```

##### Clustered Backend Implementation

```elixir
defmodule Splitio.Storage.Backend.Cluster do
  @behaviour Splitio.Storage.Backend
  alias Splitio.Cluster.Replicator

  # Reads go directly to local ETS (fast, no coordination)
  @impl true
  def get_split(name) do
    case :ets.lookup(:splitio_splits, name) do
      [{^name, split}] -> {:ok, split}
      [] -> :not_found
    end
  end

  # Writes go to local ETS, then broadcast delta (leader only)
  @impl true
  def put_split(split) do
    :ets.insert(:splitio_splits, {split.name, split})
    Replicator.broadcast_delta({:put_split, split})
    :ok
  end

  # ... etc
end
```

##### Configuration

```elixir
config :splitio,
  storage_backend: Splitio.Storage.Backend.Cluster,
  cluster: [
    # libcluster topology
    topology: [
      splitio: [
        strategy: Cluster.Strategy.Kubernetes,
        config: [...]
      ]
    ]
  ]
```

#### Redis Backend (Future)

For deployments where nodes don't form an Erlang cluster (e.g., separate Kubernetes pods communicating only via Redis).

```elixir
defmodule Splitio.Storage.Backend.Redis do
  @behaviour Splitio.Storage.Backend

  # All reads/writes go to Redis
  # No leader election needed - Redis is the coordination point
  # Uses Redix or similar client

  @impl true
  def get_split(name) do
    case Redix.command(:splitio_redis, ["HGET", "splitio:splits", name]) do
      {:ok, nil} -> :not_found
      {:ok, json} -> {:ok, Jason.decode!(json) |> Split.from_map()}
    end
  end

  @impl true
  def put_split(split) do
    json = split |> Split.to_map() |> Jason.encode!()
    Redix.command(:splitio_redis, ["HSET", "splitio:splits", split.name, json])
    :ok
  end
end
```

### Supervision Tree

The supervision tree adapts based on storage backend configuration.

#### Single-Node Mode (ETS Backend)

```
Splitio.Supervisor (Application)
├── Splitio.Storage.TableOwner (GenServer)
│   └── Owns ETS tables, survives crashes
│
├── Splitio.Sync.Supervisor (Supervisor)
│   ├── Splitio.Sync.Manager (GenServer)
│   │   └── Coordinates sync state machine
│   ├── Splitio.Sync.Splits (GenServer)
│   │   └── Fetches /splitChanges
│   ├── Splitio.Sync.Segments (DynamicSupervisor)
│   │   └── Spawns segment fetcher tasks
│   ├── Splitio.Sync.LargeSegments (DynamicSupervisor)
│   │   └── Downloads large segment files (max 5 concurrent)
│   └── Splitio.Sync.Polling (GenServer)
│       └── Periodic polling timer
│
├── Splitio.Push.Supervisor (Supervisor)
│   ├── Splitio.Push.SSE (GenServer)
│   │   └── SSE connection to Ably
│   ├── Splitio.Push.Processor (GenServer)
│   │   └── Routes SSE messages
│   └── Splitio.Push.Auth (GenServer)
│       └── JWT token refresh
│
├── Splitio.Recorder.Supervisor (Supervisor)
│   ├── Splitio.Recorder.Impressions (GenServer)
│   │   └── Flush on: timer OR queue full OR destroy
│   ├── Splitio.Recorder.Events (GenServer)
│   │   └── Flush on: timer OR queue full OR destroy
│   ├── Splitio.Recorder.ImpressionCounts (GenServer)
│   │   └── Flush counts (OPTIMIZED/NONE modes)
│   └── Splitio.Recorder.Telemetry (GenServer)
│       └── Periodic telemetry upload
│
├── Splitio.Impressions.Observer (GenServer + ETS)
│   └── Deduplication cache (LRU via ETS)
│
└── Splitio.Readiness (GenServer)
    └── Tracks ready state, notifies waiters
```

#### Clustered Mode (ETS + Cluster Backend)

Additional components for cluster coordination:

```
Splitio.Supervisor (Application)
├── Splitio.Storage.TableOwner (GenServer)
│   └── Owns ETS tables
│
├── Splitio.Cluster.Supervisor (Supervisor)
│   ├── Cluster.Supervisor (libcluster)
│   │   └── Node discovery and connection
│   ├── Splitio.Cluster.Leader (GenServer, :global registered)
│   │   └── Leader election via :global
│   ├── Splitio.Cluster.Membership (GenServer)
│   │   └── Tracks cluster members via :pg
│   └── Splitio.Cluster.Replicator (GenServer)
│       └── Broadcasts deltas, handles full state dumps
│
├── Splitio.Sync.Supervisor (Supervisor)
│   └── [Only started on leader node]
│       ├── Splitio.Sync.Manager
│       ├── Splitio.Sync.Splits
│       ├── Splitio.Sync.Segments
│       ├── Splitio.Sync.LargeSegments
│       └── Splitio.Sync.Polling
│
├── Splitio.Push.Supervisor (Supervisor)
│   └── [Only started on leader node]
│       ├── Splitio.Push.SSE
│       ├── Splitio.Push.Processor
│       └── Splitio.Push.Auth
│
├── Splitio.Recorder.Supervisor (Supervisor)
│   └── [Runs on ALL nodes - each node records its own impressions]
│       ├── Splitio.Recorder.Impressions
│       ├── Splitio.Recorder.Events
│       ├── Splitio.Recorder.ImpressionCounts
│       └── Splitio.Recorder.Telemetry
│
├── Splitio.Impressions.Observer (GenServer + ETS)
│   └── [Runs on ALL nodes - local deduplication]
│
└── Splitio.Readiness (GenServer)
    └── [Follower: ready when full state received]
```

**Key differences in clustered mode:**
- `Splitio.Cluster.Supervisor` manages cluster coordination
- `Splitio.Sync.Supervisor` and `Splitio.Push.Supervisor` only run on leader
- `Splitio.Recorder.Supervisor` runs on all nodes (each records its own traffic)
- Followers wait for full state dump before becoming ready

```

### Module Organization

```
lib/
├── split_client.ex                    # Public API
├── split_client/
│   ├── application.ex                 # OTP Application
│   ├── config.ex                      # Configuration parsing
│   ├── client.ex                      # Client struct & functions
│   ├── manager.ex                     # Manager API
│   ├── key.ex                         # Key struct (matching + bucketing)
│   │
│   ├── engine/
│   │   ├── evaluator.ex               # Main evaluation logic
│   │   ├── splitter.ex                # Bucketing & treatment selection
│   │   ├── hash/
│   │   │   ├── murmur3.ex             # Murmur3-32 and Murmur3-128
│   │   │   └── legacy.ex              # Java-style hash
│   │   └── matchers/
│   │       ├── matcher.ex             # Behaviour + dispatcher
│   │       ├── all_keys.ex
│   │       ├── segment.ex
│   │       ├── whitelist.ex
│   │       ├── numeric.ex             # EQUAL_TO, BETWEEN, etc.
│   │       ├── string.ex              # STARTS_WITH, REGEX, etc.
│   │       ├── set.ex                 # Set operations
│   │       ├── boolean.ex
│   │       ├── semver.ex              # All semver matchers
│   │       ├── dependency.ex          # IN_SPLIT_TREATMENT
│   │       ├── large_segment.ex
│   │       └── rule_based_segment.ex
│   │
│   ├── storage/
│   │   ├── storage.ex                 # Facade - routes to backend
│   │   ├── backend.ex                 # Backend behaviour
│   │   ├── table_owner.ex             # GenServer that owns ETS tables
│   │   ├── backend/
│   │   │   ├── ets.ex                 # Single-node ETS backend
│   │   │   ├── cluster.ex             # Clustered ETS backend
│   │   │   └── redis.ex               # Redis backend (future)
│   │   ├── impressions.ex             # Queue with size limit
│   │   └── events.ex                  # Queue with size limit
│   │
│   ├── cluster/
│   │   ├── supervisor.ex              # Cluster subsystem supervisor
│   │   ├── leader.ex                  # Leader election via :global
│   │   ├── membership.ex              # Cluster membership via :pg
│   │   └── replicator.ex              # State replication
│   │
│   ├── sync/
│   │   ├── manager.ex                 # Sync state machine
│   │   ├── splits.ex                  # Split fetcher
│   │   ├── segments.ex                # Segment fetcher pool
│   │   ├── large_segments.ex          # RFD downloader
│   │   └── backoff.ex                 # Exponential backoff
│   │
│   ├── push/
│   │   ├── sse.ex                     # SSE client (Mint-based)
│   │   ├── parser.ex                  # SSE message parser
│   │   ├── processor.ex               # Message routing
│   │   └── auth.ex                    # Auth token management
│   │
│   ├── recorder/
│   │   ├── impressions.ex             # Impression sender
│   │   ├── events.ex                  # Event sender
│   │   └── telemetry.ex               # Telemetry sender
│   │
│   ├── impressions/
│   │   ├── observer.ex                # Deduplication logic
│   │   ├── counter.ex                 # Impression counts
│   │   └── strategy.ex                # Mode strategies
│   │
│   ├── api/
│   │   ├── client.ex                  # HTTP client (Req/Finch)
│   │   ├── sdk.ex                     # SDK API endpoints
│   │   ├── events.ex                  # Events API endpoints
│   │   ├── auth.ex                    # Auth API endpoints
│   │   └── telemetry.ex               # Telemetry API endpoints
│   │
│   ├── models/
│   │   ├── split.ex                   # Split struct
│   │   ├── condition.ex               # Condition struct
│   │   ├── partition.ex               # Partition struct
│   │   ├── segment.ex                 # Segment struct
│   │   ├── rule_based_segment.ex      # RBS struct
│   │   ├── impression.ex              # Impression struct
│   │   └── event.ex                   # Event struct
│   │
│   └── localhost/
│       ├── file_watcher.ex            # File change detection
│       ├── yaml_parser.ex             # YAML format
│       └── json_parser.ex             # JSON format
```

### Core Structs

All data is represented as typed structs with `@enforce_keys` for required fields.

#### Split

```elixir
defmodule SplitClient.Models.Split do
  @moduledoc "Feature flag definition"

  @type status :: :active | :archived
  @type algo :: :legacy | :murmur

  @type t :: %__MODULE__{
    name: String.t(),
    traffic_type_name: String.t(),
    killed: boolean(),
    status: status(),
    default_treatment: String.t(),
    change_number: non_neg_integer(),
    algo: algo(),
    traffic_allocation: 0..100,
    traffic_allocation_seed: integer(),
    seed: integer(),
    conditions: [SplitClient.Models.Condition.t()],
    configurations: %{String.t() => String.t() | nil},
    sets: MapSet.t(String.t()),
    impressions_disabled: boolean(),
    prerequisites: [SplitClient.Models.Prerequisite.t()]
  }

  @enforce_keys [:name, :default_treatment, :change_number]
  defstruct [
    :name,
    :traffic_type_name,
    :default_treatment,
    :change_number,
    :seed,
    :traffic_allocation_seed,
    killed: false,
    status: :active,
    algo: :murmur,
    traffic_allocation: 100,
    conditions: [],
    configurations: %{},
    sets: MapSet.new(),
    impressions_disabled: false,
    prerequisites: []
  ]
end
```

#### Condition

```elixir
defmodule SplitClient.Models.Condition do
  @moduledoc "Targeting condition within a split"

  @type condition_type :: :rollout | :whitelist

  @type t :: %__MODULE__{
    condition_type: condition_type(),
    matcher_group: SplitClient.Models.MatcherGroup.t(),
    partitions: [SplitClient.Models.Partition.t()],
    label: String.t()
  }

  @enforce_keys [:condition_type, :matcher_group, :partitions, :label]
  defstruct [:condition_type, :matcher_group, :partitions, :label]
end
```

#### MatcherGroup

```elixir
defmodule SplitClient.Models.MatcherGroup do
  @moduledoc "Group of matchers combined with AND logic"

  @type combiner :: :and  # Only AND supported

  @type t :: %__MODULE__{
    combiner: combiner(),
    matchers: [SplitClient.Models.Matcher.t()]
  }

  @enforce_keys [:matchers]
  defstruct combiner: :and, matchers: []
end
```

#### Matcher

```elixir
defmodule SplitClient.Models.Matcher do
  @moduledoc "Individual matching rule"

  @type matcher_type ::
    :all_keys | :in_segment | :whitelist |
    :equal_to | :greater_than_or_equal_to | :less_than_or_equal_to | :between |
    :equal_to_set | :part_of_set | :contains_all_of_set | :contains_any_of_set |
    :starts_with | :ends_with | :contains_string | :matches_string |
    :equal_to_boolean | :in_split_treatment |
    :equal_to_semver | :greater_than_or_equal_to_semver |
    :less_than_or_equal_to_semver | :between_semver | :in_list_semver |
    :in_large_segment | :in_rule_based_segment

  @type data_type :: :number | :datetime

  @type t :: %__MODULE__{
    matcher_type: matcher_type(),
    negate: boolean(),
    attribute: String.t() | nil,
    # Type-specific data (one of these will be set)
    segment_name: String.t() | nil,
    whitelist: [String.t()] | nil,
    value: number() | String.t() | boolean() | nil,
    data_type: data_type() | nil,
    start_value: number() | String.t() | nil,
    end_value: number() | String.t() | nil,
    dependency_split: String.t() | nil,
    dependency_treatments: [String.t()] | nil
  }

  @enforce_keys [:matcher_type]
  defstruct [
    :matcher_type,
    :attribute,
    :segment_name,
    :whitelist,
    :value,
    :data_type,
    :start_value,
    :end_value,
    :dependency_split,
    :dependency_treatments,
    negate: false
  ]
end
```

#### Partition

```elixir
defmodule SplitClient.Models.Partition do
  @moduledoc "Treatment allocation within a condition"

  @type t :: %__MODULE__{
    treatment: String.t(),
    size: 0..100
  }

  @enforce_keys [:treatment, :size]
  defstruct [:treatment, :size]
end
```

#### Prerequisite

```elixir
defmodule SplitClient.Models.Prerequisite do
  @moduledoc "Feature flag dependency"

  @type t :: %__MODULE__{
    feature_flag: String.t(),
    treatments: [String.t()]
  }

  @enforce_keys [:feature_flag, :treatments]
  defstruct [:feature_flag, :treatments]
end
```

#### Segment

```elixir
defmodule SplitClient.Models.Segment do
  @moduledoc "User segment with incremental updates"

  @type t :: %__MODULE__{
    name: String.t(),
    keys: MapSet.t(String.t()),
    change_number: integer()
  }

  @enforce_keys [:name]
  defstruct [
    :name,
    keys: MapSet.new(),
    change_number: -1
  ]

  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{keys: keys}, key), do: MapSet.member?(keys, key)

  @spec update(t(), [String.t()], [String.t()], integer()) :: t()
  def update(%__MODULE__{keys: keys} = segment, to_add, to_remove, change_number) do
    keys =
      keys
      |> MapSet.union(MapSet.new(to_add))
      |> MapSet.difference(MapSet.new(to_remove))

    %{segment | keys: keys, change_number: change_number}
  end
end
```

#### RuleBasedSegment

```elixir
defmodule SplitClient.Models.RuleBasedSegment do
  @moduledoc "Dynamic segment defined by rules"

  @type status :: :active | :archived

  @type t :: %__MODULE__{
    name: String.t(),
    traffic_type_name: String.t(),
    change_number: non_neg_integer(),
    status: status(),
    conditions: [SplitClient.Models.Condition.t()],
    excluded: SplitClient.Models.Excluded.t()
  }

  @enforce_keys [:name, :change_number]
  defstruct [
    :name,
    :traffic_type_name,
    :change_number,
    status: :active,
    conditions: [],
    excluded: %SplitClient.Models.Excluded{}
  ]
end

defmodule SplitClient.Models.Excluded do
  @moduledoc "Exclusion rules for rule-based segments"

  @type t :: %__MODULE__{
    keys: MapSet.t(String.t()),
    segments: [SplitClient.Models.ExcludedSegment.t()]
  }

  defstruct keys: MapSet.new(), segments: []
end

defmodule SplitClient.Models.ExcludedSegment do
  @moduledoc "Reference to excluded segment"

  @type segment_type :: :standard | :rule_based | :large

  @type t :: %__MODULE__{
    name: String.t(),
    type: segment_type()
  }

  @enforce_keys [:name, :type]
  defstruct [:name, :type]
end
```

#### Impression

```elixir
defmodule SplitClient.Models.Impression do
  @moduledoc "Record of a treatment evaluation"

  @type t :: %__MODULE__{
    key: String.t(),
    bucketing_key: String.t() | nil,
    feature: String.t(),
    treatment: String.t(),
    label: String.t(),
    change_number: non_neg_integer(),
    time: non_neg_integer(),
    previous_time: non_neg_integer() | nil,
    properties: map() | nil
  }

  @enforce_keys [:key, :feature, :treatment, :label, :change_number, :time]
  defstruct [
    :key,
    :bucketing_key,
    :feature,
    :treatment,
    :label,
    :change_number,
    :time,
    :previous_time,
    :properties
  ]
end
```

#### Event

```elixir
defmodule SplitClient.Models.Event do
  @moduledoc "Custom tracking event"

  @type t :: %__MODULE__{
    key: String.t(),
    traffic_type: String.t(),
    event_type: String.t(),
    value: number() | nil,
    timestamp: non_neg_integer(),
    properties: map() | nil
  }

  @enforce_keys [:key, :traffic_type, :event_type, :timestamp]
  defstruct [
    :key,
    :traffic_type,
    :event_type,
    :value,
    :timestamp,
    :properties
  ]
end
```

#### EvaluationResult

```elixir
defmodule SplitClient.Models.EvaluationResult do
  @moduledoc "Result of evaluating a feature flag"

  @type t :: %__MODULE__{
    treatment: String.t(),
    label: String.t(),
    config: String.t() | nil,
    change_number: non_neg_integer(),
    impressions_disabled: boolean()
  }

  @enforce_keys [:treatment, :label, :change_number]
  defstruct [
    :treatment,
    :label,
    :config,
    :change_number,
    impressions_disabled: false
  ]
end
```

#### SplitView (Manager API)

```elixir
defmodule SplitClient.Models.SplitView do
  @moduledoc "Public view of a feature flag"

  @type t :: %__MODULE__{
    name: String.t(),
    traffic_type: String.t() | nil,
    killed: boolean(),
    treatments: [String.t()],
    change_number: non_neg_integer(),
    configs: %{String.t() => String.t() | nil},
    default_treatment: String.t(),
    sets: [String.t()],
    impressions_disabled: boolean(),
    prerequisites: [%{feature: String.t(), treatments: [String.t()]}]
  }

  @enforce_keys [:name, :change_number, :default_treatment]
  defstruct [
    :name,
    :traffic_type,
    :change_number,
    :default_treatment,
    killed: false,
    treatments: [],
    configs: %{},
    sets: [],
    impressions_disabled: false,
    prerequisites: []
  ]

  @spec from_split(SplitClient.Models.Split.t()) :: t()
  def from_split(%SplitClient.Models.Split{} = split) do
    treatments =
      split.conditions
      |> Enum.flat_map(& &1.partitions)
      |> Enum.map(& &1.treatment)
      |> Enum.uniq()

    %__MODULE__{
      name: split.name,
      traffic_type: split.traffic_type_name,
      killed: split.killed,
      treatments: treatments,
      change_number: split.change_number,
      configs: split.configurations,
      default_treatment: split.default_treatment,
      sets: MapSet.to_list(split.sets),
      impressions_disabled: split.impressions_disabled,
      prerequisites: Enum.map(split.prerequisites, fn p ->
        %{feature: p.feature_flag, treatments: p.treatments}
      end)
    }
  end
end
```

#### Key

```elixir
defmodule SplitClient.Key do
  @moduledoc "Composite key for evaluation"

  @type t :: %__MODULE__{
    matching_key: String.t(),
    bucketing_key: String.t() | nil
  }

  @enforce_keys [:matching_key]
  defstruct [:matching_key, :bucketing_key]

  @doc "Create key from string or struct"
  @spec new(String.t() | t()) :: t()
  def new(%__MODULE__{} = key), do: key
  def new(key) when is_binary(key), do: %__MODULE__{matching_key: key}

  @doc "Get the bucketing key (falls back to matching key)"
  @spec bucketing_key(t()) :: String.t()
  def bucketing_key(%__MODULE__{bucketing_key: nil, matching_key: mk}), do: mk
  def bucketing_key(%__MODULE__{bucketing_key: bk}), do: bk
end
```

#### Config

```elixir
defmodule SplitClient.Config do
  @moduledoc "SDK configuration"

  @type mode :: :standalone | :consumer | :localhost
  @type impressions_mode :: :optimized | :debug | :none

  @type t :: %__MODULE__{
    api_key: String.t(),
    mode: mode(),
    streaming_enabled: boolean(),
    features_refresh_rate: pos_integer(),
    segments_refresh_rate: pos_integer(),
    impressions_mode: impressions_mode(),
    impressions_refresh_rate: pos_integer(),
    impressions_queue_size: pos_integer(),
    impressions_bulk_size: pos_integer(),
    events_refresh_rate: pos_integer(),
    events_queue_size: pos_integer(),
    events_bulk_size: pos_integer(),
    connection_timeout: pos_integer(),
    read_timeout: pos_integer(),
    sdk_url: String.t(),
    events_url: String.t(),
    auth_url: String.t(),
    streaming_url: String.t(),
    telemetry_url: String.t(),
    split_file: String.t() | nil,
    localhost_refresh_enabled: boolean(),
    flag_sets_filter: [String.t()] | nil,
    labels_enabled: boolean(),
    ip_addresses_enabled: boolean()
  }

  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    :split_file,
    :flag_sets_filter,
    mode: :standalone,
    streaming_enabled: true,
    features_refresh_rate: 30,
    segments_refresh_rate: 30,
    impressions_mode: :optimized,
    impressions_refresh_rate: 300,
    impressions_queue_size: 10_000,
    impressions_bulk_size: 5_000,
    events_refresh_rate: 60,
    events_queue_size: 10_000,
    events_bulk_size: 5_000,
    connection_timeout: 10_000,
    read_timeout: 60_000,
    sdk_url: "https://sdk.split.io/api",
    events_url: "https://events.split.io/api",
    auth_url: "https://auth.split.io/api",
    streaming_url: "https://streaming.split.io",
    telemetry_url: "https://telemetry.split.io/api",
    localhost_refresh_enabled: false,
    labels_enabled: true,
    ip_addresses_enabled: true
  ]
end
```

### Recorder Implementation

The recorder subsystem handles batched sync of impressions, events, and counts to Split APIs.

#### Storage.Impressions (Queue)

```elixir
defmodule SplitClient.Storage.Impressions do
  @moduledoc "Bounded queue for impressions awaiting sync"
  use GenServer

  defstruct [
    :queue,          # :queue.queue() of %Impression{}
    :size,           # current queue size
    :max_size,       # from config.impressions_queue_size
    :bulk_size,      # from config.impressions_bulk_size
    :recorder_pid    # pid to notify when bulk_size reached
  ]

  def push(impression) do
    GenServer.call(__MODULE__, {:push, impression})
  end

  def pop_batch(count) do
    GenServer.call(__MODULE__, {:pop, count})
  end

  def handle_call({:push, impression}, _from, %{size: size, max_size: max} = state) 
      when size >= max do
    # Queue full - drop impression
    SplitClient.Telemetry.increment(:impressions_dropped)
    {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:push, impression}, _from, state) do
    new_queue = :queue.in(impression, state.queue)
    new_size = state.size + 1
    new_state = %{state | queue: new_queue, size: new_size}

    # Notify recorder if we hit bulk size threshold
    if new_size >= state.bulk_size do
      send(state.recorder_pid, :flush_impressions)
    end

    {:reply, :ok, new_state}
  end

  def handle_call({:pop, count}, _from, state) do
    {items, remaining_queue, popped_count} = pop_n(state.queue, count, [])
    new_state = %{state | queue: remaining_queue, size: state.size - popped_count}
    {:reply, items, new_state}
  end
end
```

#### Recorder.Impressions (Flusher)

```elixir
defmodule SplitClient.Recorder.Impressions do
  @moduledoc "Batched impression sync to Split API"
  use GenServer

  defstruct [
    :timer_ref,
    :config,
    :api_client
  ]

  def init(config) do
    timer_ref = schedule_flush(config.impressions_refresh_rate)
    {:ok, %__MODULE__{timer_ref: timer_ref, config: config}}
  end

  # Trigger 1: Timer fires
  def handle_info(:flush, state) do
    flush_all(state)
    timer_ref = schedule_flush(state.config.impressions_refresh_rate)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  # Trigger 2: Queue hit bulk size (notified by Storage.Impressions)
  def handle_info(:flush_impressions, state) do
    flush_all(state)
    {:noreply, state}
  end

  # Trigger 3: destroy() called
  def handle_call(:flush_and_stop, _from, state) do
    flush_all(state)
    {:stop, :normal, :ok, state}
  end

  defp flush_all(state) do
    flush_loop(state.config.impressions_bulk_size, state)
  end

  defp flush_loop(bulk_size, state) do
    case SplitClient.Storage.Impressions.pop_batch(bulk_size) do
      [] -> 
        :ok
      impressions ->
        payload = format_bulk_payload(impressions)
        SplitClient.Api.Events.post_impressions(payload, state.config)
        # Continue if there might be more
        if length(impressions) == bulk_size do
          flush_loop(bulk_size, state)
        end
    end
  end

  defp format_bulk_payload(impressions) do
    impressions
    |> Enum.group_by(& &1.feature)
    |> Enum.map(fn {feature, imps} ->
      %{
        "f" => feature,
        "i" => Enum.map(imps, &format_impression/1)
      }
    end)
  end

  defp format_impression(%Impression{} = imp) do
    base = %{
      "k" => imp.key,
      "t" => imp.treatment,
      "m" => imp.time,
      "c" => imp.change_number,
      "r" => imp.label
    }

    base
    |> maybe_put("b", imp.bucketing_key, imp.bucketing_key != imp.key)
    |> maybe_put("pt", imp.previous_time, imp.previous_time != nil)
  end

  defp schedule_flush(interval_seconds) do
    Process.send_after(self(), :flush, interval_seconds * 1000)
  end
end
```

#### Recorder.ImpressionCounts

```elixir
defmodule SplitClient.Recorder.ImpressionCounts do
  @moduledoc "Batched impression count sync (OPTIMIZED/NONE modes)"
  use GenServer

  @hour_ms 3_600_000

  defstruct [
    :counts,      # %{{feature, hour_timestamp} => count}
    :timer_ref,
    :config
  ]

  def increment(feature, timestamp) do
    hour = truncate_to_hour(timestamp)
    GenServer.cast(__MODULE__, {:increment, feature, hour})
  end

  def handle_cast({:increment, feature, hour}, state) do
    key = {feature, hour}
    counts = Map.update(state.counts, key, 1, &(&1 + 1))
    {:noreply, %{state | counts: counts}}
  end

  def handle_info(:flush, state) do
    if map_size(state.counts) > 0 do
      payload = format_counts_payload(state.counts)
      SplitClient.Api.Events.post_impression_counts(payload, state.config)
    end

    timer_ref = schedule_flush(state.config.impressions_refresh_rate)
    {:noreply, %{state | counts: %{}, timer_ref: timer_ref}}
  end

  defp format_counts_payload(counts) do
    pf = Enum.map(counts, fn {{feature, hour}, count} ->
      %{"f" => feature, "m" => hour, "rc" => count}
    end)
    %{"pf" => pf}
  end

  defp truncate_to_hour(timestamp_ms) do
    timestamp_ms - rem(timestamp_ms, @hour_ms)
  end
end
```

### SSE Message Structs

```elixir
defmodule SplitClient.Push.Messages do
  @moduledoc "SSE message types"

  defmodule SplitUpdate do
    @type t :: %__MODULE__{
      change_number: non_neg_integer(),
      previous_change_number: non_neg_integer() | nil,
      definition: String.t() | nil,
      compression: :none | :gzip | :zlib
    }
    defstruct [:change_number, :previous_change_number, :definition, compression: :none]
  end

  defmodule SplitKill do
    @type t :: %__MODULE__{
      change_number: non_neg_integer(),
      split_name: String.t(),
      default_treatment: String.t()
    }
    @enforce_keys [:change_number, :split_name, :default_treatment]
    defstruct [:change_number, :split_name, :default_treatment]
  end

  defmodule SegmentUpdate do
    @type t :: %__MODULE__{
      change_number: non_neg_integer(),
      segment_name: String.t()
    }
    @enforce_keys [:change_number, :segment_name]
    defstruct [:change_number, :segment_name]
  end

  defmodule RuleBasedSegmentUpdate do
    @type t :: %__MODULE__{
      change_number: non_neg_integer(),
      previous_change_number: non_neg_integer() | nil,
      definition: String.t() | nil,
      compression: :none | :gzip | :zlib
    }
    defstruct [:change_number, :previous_change_number, :definition, compression: :none]
  end

  defmodule LargeSegmentUpdate do
    @type t :: %__MODULE__{
      name: String.t(),
      notification_type: :new_definition | :empty,
      change_number: non_neg_integer(),
      spec_version: String.t(),
      rfd: SplitClient.Push.Messages.RFD.t() | nil
    }
    @enforce_keys [:name, :notification_type, :change_number]
    defstruct [:name, :notification_type, :change_number, :spec_version, :rfd]
  end

  defmodule RFD do
    @type t :: %__MODULE__{
      url: String.t(),
      method: String.t(),
      headers: %{String.t() => String.t()},
      format: :csv,
      total_keys: non_neg_integer(),
      file_size: non_neg_integer(),
      expires_at: non_neg_integer()
    }
    @enforce_keys [:url, :expires_at]
    defstruct [:url, :total_keys, :file_size, :expires_at, method: "GET", headers: %{}, format: :csv]
  end

  defmodule Control do
    @type control_type :: :streaming_enabled | :streaming_paused | :streaming_disabled
    @type t :: %__MODULE__{control_type: control_type()}
    @enforce_keys [:control_type]
    defstruct [:control_type]
  end

  defmodule Occupancy do
    @type t :: %__MODULE__{
      channel: String.t(),
      publishers: non_neg_integer()
    }
    @enforce_keys [:channel, :publishers]
    defstruct [:channel, :publishers]
  end
end
```

### JSON Parsing to Structs

Parse at the boundary, work with structs internally. Each model has a `from_json/1` function.

```elixir
defmodule SplitClient.Models.Split do
  # ... struct definition above ...

  @doc "Parse split from JSON map (API response)"
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"name" => name} = json) do
    {:ok,
      %__MODULE__{
        name: name,
        traffic_type_name: json["trafficTypeName"],
        killed: json["killed"] || false,
        status: parse_status(json["status"]),
        default_treatment: json["defaultTreatment"],
        change_number: json["changeNumber"],
        algo: parse_algo(json["algo"]),
        traffic_allocation: json["trafficAllocation"] || 100,
        traffic_allocation_seed: json["trafficAllocationSeed"],
        seed: json["seed"],
        conditions: parse_conditions(json["conditions"] || []),
        configurations: json["configurations"] || %{},
        sets: MapSet.new(json["sets"] || []),
        impressions_disabled: json["impressionsDisabled"] || false,
        prerequisites: parse_prerequisites(json["prerequisites"] || [])
      }}
  end
  def from_json(_), do: {:error, :invalid_split}

  defp parse_status("ACTIVE"), do: :active
  defp parse_status("ARCHIVED"), do: :archived
  defp parse_status(_), do: :active

  defp parse_algo(1), do: :legacy
  defp parse_algo(2), do: :murmur
  defp parse_algo(_), do: :murmur

  defp parse_conditions(conditions) do
    Enum.map(conditions, &SplitClient.Models.Condition.from_json/1)
  end

  defp parse_prerequisites(prereqs) do
    Enum.map(prereqs, fn %{"n" => name, "ts" => treatments} ->
      %SplitClient.Models.Prerequisite{feature_flag: name, treatments: treatments}
    end)
  end
end

defmodule SplitClient.Models.Condition do
  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      condition_type: parse_condition_type(json["conditionType"]),
      matcher_group: SplitClient.Models.MatcherGroup.from_json(json["matcherGroup"]),
      partitions: Enum.map(json["partitions"] || [], &parse_partition/1),
      label: json["label"] || "default rule"
    }
  end

  defp parse_condition_type("ROLLOUT"), do: :rollout
  defp parse_condition_type("WHITELIST"), do: :whitelist
  defp parse_condition_type(_), do: :rollout

  defp parse_partition(%{"treatment" => t, "size" => s}) do
    %SplitClient.Models.Partition{treatment: t, size: s}
  end
end

defmodule SplitClient.Models.Matcher do
  @matcher_type_map %{
    "ALL_KEYS" => :all_keys,
    "IN_SEGMENT" => :in_segment,
    "WHITELIST" => :whitelist,
    "EQUAL_TO" => :equal_to,
    "GREATER_THAN_OR_EQUAL_TO" => :greater_than_or_equal_to,
    "LESS_THAN_OR_EQUAL_TO" => :less_than_or_equal_to,
    "BETWEEN" => :between,
    "EQUAL_TO_SET" => :equal_to_set,
    "PART_OF_SET" => :part_of_set,
    "CONTAINS_ALL_OF_SET" => :contains_all_of_set,
    "CONTAINS_ANY_OF_SET" => :contains_any_of_set,
    "STARTS_WITH" => :starts_with,
    "ENDS_WITH" => :ends_with,
    "CONTAINS_STRING" => :contains_string,
    "MATCHES_STRING" => :matches_string,
    "EQUAL_TO_BOOLEAN" => :equal_to_boolean,
    "IN_SPLIT_TREATMENT" => :in_split_treatment,
    "EQUAL_TO_SEMVER" => :equal_to_semver,
    "GREATER_THAN_OR_EQUAL_TO_SEMVER" => :greater_than_or_equal_to_semver,
    "LESS_THAN_OR_EQUAL_TO_SEMVER" => :less_than_or_equal_to_semver,
    "BETWEEN_SEMVER" => :between_semver,
    "IN_LIST_SEMVER" => :in_list_semver,
    "IN_LARGE_SEGMENT" => :in_large_segment,
    "IN_RULE_BASED_SEGMENT" => :in_rule_based_segment
  }

  @spec from_json(map()) :: t()
  def from_json(json) do
    matcher_type = Map.get(@matcher_type_map, json["matcherType"], :unknown)
    attribute = get_in(json, ["keySelector", "attribute"])

    base = %__MODULE__{
      matcher_type: matcher_type,
      negate: json["negate"] || false,
      attribute: attribute
    }

    parse_matcher_data(base, matcher_type, json)
  end

  defp parse_matcher_data(base, :in_segment, json) do
    %{base | segment_name: get_in(json, ["userDefinedSegmentMatcherData", "segmentName"])}
  end

  defp parse_matcher_data(base, :in_large_segment, json) do
    %{base | segment_name: get_in(json, ["userDefinedLargeSegmentMatcherData", "largeSegmentName"])}
  end

  defp parse_matcher_data(base, :in_rule_based_segment, json) do
    %{base | segment_name: get_in(json, ["userDefinedSegmentMatcherData", "segmentName"])}
  end

  defp parse_matcher_data(base, type, json) when type in [:whitelist, :starts_with, :ends_with, :contains_string] do
    %{base | whitelist: get_in(json, ["whitelistMatcherData", "whitelist"]) || []}
  end

  defp parse_matcher_data(base, type, json) when type in [:equal_to_set, :part_of_set, :contains_all_of_set, :contains_any_of_set, :in_list_semver] do
    %{base | whitelist: get_in(json, ["whitelistMatcherData", "whitelist"]) || []}
  end

  defp parse_matcher_data(base, type, json) when type in [:equal_to, :greater_than_or_equal_to, :less_than_or_equal_to] do
    data = json["unaryNumericMatcherData"] || %{}
    %{base |
      value: data["value"],
      data_type: parse_data_type(data["dataType"])
    }
  end

  defp parse_matcher_data(base, :between, json) do
    data = json["betweenMatcherData"] || %{}
    %{base |
      start_value: data["start"],
      end_value: data["end"],
      data_type: parse_data_type(data["dataType"])
    }
  end

  defp parse_matcher_data(base, type, json) when type in [:equal_to_semver, :greater_than_or_equal_to_semver, :less_than_or_equal_to_semver, :matches_string] do
    %{base | value: get_in(json, ["stringMatcherData", "string"])}
  end

  defp parse_matcher_data(base, :between_semver, json) do
    data = json["betweenStringMatcherData"] || %{}
    %{base | start_value: data["start"], end_value: data["end"]}
  end

  defp parse_matcher_data(base, :equal_to_boolean, json) do
    %{base | value: get_in(json, ["booleanMatcherData", "value"])}
  end

  defp parse_matcher_data(base, :in_split_treatment, json) do
    data = json["dependencyMatcherData"] || %{}
    %{base |
      dependency_split: data["split"],
      dependency_treatments: data["treatments"] || []
    }
  end

  defp parse_matcher_data(base, _type, _json), do: base

  defp parse_data_type("NUMBER"), do: :number
  defp parse_data_type("DATETIME"), do: :datetime
  defp parse_data_type(_), do: :number
end
```

### ETS Table Design

| Table | Type | Access | Purpose |
|-------|------|--------|---------|
| `:split_client_splits` | `:set` | `:protected` | `{name, %Split{}}` |
| `:split_client_segments` | `:set` | `:protected` | `{name, MapSet.t()}` |
| `:split_client_segment_cn` | `:set` | `:protected` | `{name, change_number}` |
| `:split_client_rbs` | `:set` | `:protected` | `{name, %RuleBasedSegment{}}` |
| `:split_client_large_segments` | `:set` | `:protected` | `{name, MapSet.t()}` |
| `:split_client_large_segment_cn` | `:set` | `:protected` | `{name, change_number}` |
| `:split_client_impressions_cache` | `:set` | `:public` | `{hash, timestamp}` LRU |

**Read pattern (zero-copy):**
```elixir
def get_split(name) do
  case :ets.lookup(:split_client_splits, name) do
    [{^name, split}] -> {:ok, split}
    [] -> :not_found
  end
end
```

**Segment membership (O(1)):**
```elixir
def segment_contains?(name, key) do
  case :ets.lookup(:split_client_segments, name) do
    [{^name, keys}] -> MapSet.member?(keys, key)
    [] -> false
  end
end
```

### Evaluation Flow

```
┌──────────────────────────────────────────────────────────────┐
│ SplitClient.get_treatment(key, split_name, attributes)       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Input validation (key, split_name, attributes)            │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. ETS lookup: :ets.lookup(:split_client_splits, name)       │
│    No GenServer call - direct ETS read                       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Evaluator.evaluate(split, key, bucketing_key, attributes) │
│    - Check killed                                            │
│    - Check prerequisites (recursive evaluate)                │
│    - Check traffic allocation                                │
│    - Match conditions                                        │
│    - Calculate bucket                                        │
│    - Select treatment                                        │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Record impression (async cast to GenServer)               │
│    - Observer.test_and_set for deduplication                 │
│    - Queue impression if not deduplicated                    │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Return {treatment, config, impression}                    │
└──────────────────────────────────────────────────────────────┘
```

### Sync State Machine

```
                    ┌─────────────────┐
                    │   :initializing │
                    └────────┬────────┘
                             │ initial sync complete
                             ▼
     ┌──────────────────────────────────────────┐
     │              :streaming                   │
     │  (SSE connected, real-time updates)       │
     └──────────────────┬───────────────────────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
         ▼              ▼              ▼
  STREAMING_PAUSED   SSE error    STREAMING_DISABLED
         │              │              │
         ▼              ▼              ▼
     ┌──────────────────────────────────────────┐
     │              :polling                     │
     │  (periodic HTTP fetch, backoff on error)  │
     └──────────────────┬───────────────────────┘
                        │
                        │ STREAMING_ENABLED + SSE reconnect
                        ▼
     ┌──────────────────────────────────────────┐
     │              :streaming                   │
     └──────────────────────────────────────────┘
```

**GenServer state:**
```elixir
defmodule SplitClient.Sync.Manager do
  use GenServer

  defstruct [
    :mode,           # :streaming | :polling | :initializing
    :splits_cn,      # current splits change number
    :rbs_cn,         # rule-based segments change number
    :segment_cns,    # %{segment_name => change_number}
    :ready?,         # boolean
    :backoff         # backoff state
  ]
end
```

### Impression Deduplication

```elixir
defmodule SplitClient.Impressions.Observer do
  @max_cache_size 500_000
  @hour_ms 3_600_000

  def test_and_set(impression) do
    hash = hash_impression(impression)
    current_time = System.system_time(:millisecond)
    current_hour = truncate_to_hour(current_time)

    case :ets.lookup(@table, hash) do
      [{^hash, previous_time}] ->
        :ets.insert(@table, {hash, current_time})
        maybe_evict_lru()
        %{impression | previous_time: previous_time}

      [] ->
        :ets.insert(@table, {hash, current_time})
        maybe_evict_lru()
        %{impression | previous_time: nil}
    end
  end

  defp hash_impression(imp) do
    data = "#{imp.key}:#{imp.split}:#{imp.treatment}:#{imp.label}:#{imp.change_number}"
    <<hash::64, _::64>> = SplitClient.Hash.Murmur3.hash128(data, 0)
    hash
  end

  defp truncate_to_hour(timestamp_ms) do
    timestamp_ms - rem(timestamp_ms, @hour_ms)
  end
end
```

### SSE Client (Mint-based)

```elixir
defmodule SplitClient.Push.SSE do
  use GenServer

  @keepalive_timeout 70_000

  defstruct [
    :conn,           # Mint.HTTP connection
    :request_ref,    # current request reference
    :buffer,         # incomplete SSE data buffer
    :channels,       # subscribed channels
    :token,          # current auth token
    :status          # :connecting | :connected | :disconnected
  ]

  def handle_info({:tcp, socket, data}, state) do
    case Mint.HTTP.stream(state.conn, {:tcp, socket, data}) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        Enum.reduce(responses, state, &handle_response/2)
      {:error, conn, reason, _responses} ->
        handle_disconnect(reason, %{state | conn: conn})
    end
  end

  defp handle_response({:data, _ref, data}, state) do
    {events, buffer} = parse_sse(state.buffer <> data)
    Enum.each(events, &SplitClient.Push.Processor.handle_event/1)
    %{state | buffer: buffer}
  end
end
```

### Configuration

```elixir
config :split_client,
  api_key: "sdk-xxx",
  
  # Operation mode
  mode: :standalone,  # :standalone | :consumer | :localhost
  
  # Sync
  streaming_enabled: true,
  features_refresh_rate: 30,
  segments_refresh_rate: 30,
  
  # Impressions
  impressions_mode: :optimized,  # :optimized | :debug | :none
  impressions_refresh_rate: 300,
  impressions_queue_size: 10_000,
  
  # Events
  events_refresh_rate: 60,
  events_queue_size: 10_000,
  
  # URLs (optional overrides)
  sdk_url: "https://sdk.split.io/api",
  events_url: "https://events.split.io/api",
  auth_url: "https://auth.split.io/api",
  streaming_url: "https://streaming.split.io",
  
  # Localhost
  split_file: nil,
  localhost_refresh_enabled: false
```

### Public API

```elixir
defmodule SplitClient do
  @moduledoc "Split.io feature flag client for Elixir"

  # Core evaluation
  def get_treatment(key, split_name, attributes \\ %{}, opts \\ [])
  def get_treatment_with_config(key, split_name, attributes \\ %{}, opts \\ [])
  def get_treatments(key, split_names, attributes \\ %{}, opts \\ [])
  def get_treatments_with_config(key, split_names, attributes \\ %{}, opts \\ [])

  # Flag sets
  def get_treatments_by_flag_set(key, flag_set, attributes \\ %{}, opts \\ [])
  def get_treatments_by_flag_sets(key, flag_sets, attributes \\ %{}, opts \\ [])

  # Event tracking
  def track(key, traffic_type, event_type, value \\ nil, properties \\ %{})

  # SDK events
  def on(event, callback) when event in [:sdk_ready, :sdk_update]

  # Lifecycle
  def block_until_ready(timeout_ms \\ 10_000)
  def ready?()
  def destroy()
end

defmodule SplitClient.Manager do
  def splits()
  def split(name)
  def split_names()
end
```

### Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:req, "~> 0.4"},           # HTTP client
    {:mint, "~> 1.5"},          # Low-level HTTP for SSE
    {:jason, "~> 1.4"},         # JSON parsing
    {:yaml_elixir, "~> 2.9"},   # YAML parsing (localhost mode)
    {:murmur, "~> 1.0"},        # Murmur3 NIF (or pure Elixir impl)
    {:telemetry, "~> 1.2"}      # Telemetry integration
  ]
end
```

### Telemetry Events

```elixir
# Evaluation
[:split_client, :evaluate, :start]
[:split_client, :evaluate, :stop]
[:split_client, :evaluate, :exception]

# Sync
[:split_client, :sync, :splits, :start | :stop | :error]
[:split_client, :sync, :segments, :start | :stop | :error]
[:split_client, :sync, :large_segments, :start | :stop | :error]

# SSE
[:split_client, :sse, :connect | :disconnect | :message | :error]

# HTTP
[:split_client, :http, :request, :start | :stop | :error]
```

### Error Handling Strategy

| Error | Action |
|-------|--------|
| Split not found | Return `"control"`, log warning |
| Attribute missing | Return `false` for matcher, log debug |
| Type mismatch | Return `false` for matcher, log warning |
| HTTP timeout | Retry with backoff |
| SSE disconnect | Reconnect with backoff, fallback to polling |
| ETS table missing | Crash (supervisor restarts) |
| Queue full | Drop item, increment telemetry counter |

### Testing Strategy

```elixir
# Unit tests - pure functions
test "murmur3 hash consistency"
test "legacy hash consistency"
test "bucket calculation"
test "all matchers"
test "evaluation algorithm"

# Integration tests - with ETS
test "storage operations"
test "impression deduplication"
test "sync state machine"

# Contract tests - mock HTTP
test "splitChanges parsing"
test "segmentChanges parsing"
test "SSE message parsing"

# Property tests
property "bucket always 1-100"
property "hash deterministic"
property "evaluation deterministic for same input"
```
