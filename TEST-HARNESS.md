# Split SDK Test Harness

Language-agnostic test specifications for validating Split SDK implementations.

Reference: [splitio/go-split-commons](https://github.com/splitio/go-split-commons)

---

## Overview

These tests verify behavioral correctness independent of implementation language. Each test specifies:
- **Input**: Data to set up and parameters to pass
- **Expected Output**: Exact result the SDK must produce
- **Notes**: Edge cases and implementation hints

---

## 1. Hash Functions

The SDK must implement two hash algorithms for bucketing.

### 1.1 Murmur3 (algo=2)

32-bit MurmurHash3 with seed.

| Key | Seed | Expected Hash | Bucket (1-100) |
|-----|------|---------------|----------------|
| `"SOME_TEST"` | `12345` | *impl-specific* | *consistent* |

**Bucket formula:** `abs(hash % 100) + 1`

### 1.2 Legacy Hash (algo=1)

Java-style polynomial hash XOR seed.

```
hash = 0
for char in key:
  hash = 31 * hash + char_code
return hash ^ seed
```

### 1.3 Hash Consistency Tests

Use `testdata/expected-treatments.csv` to verify hash determinism.

**Split Config:**
```json
{
  "algo": 2,
  "seed": -605938843,
  "trafficAllocation": 100,
  "trafficAllocationSeed": -1364119282,
  "partitions": [
    {"treatment": "on", "size": 50},
    {"treatment": "off", "size": 50}
  ]
}
```

**Test Data (sample):**

| Key | Expected Treatment |
|-----|-------------------|
| `06D76B10-0006-0000-0000-000000000000` | `off` |
| `06EAA037-0006-0000-0000-000000000000` | `on` |
| `0576EC3E-0006-0000-0000-000000000000` | `off` |
| `04FE137C-0006-0000-0000-000000000000` | `on` |
| `06AEDA4C-0006-0000-0000-000000000000` | `on` |
| `01263B59-0001-0000-0000-000000000000` | `off` |
| `0172BAA7-0003-0000-0000-000000000000` | `on` |
| `01955ED6-0002-0000-0000-000000000000` | `off` |

Full dataset: 1264 entries in `expected-treatments.csv`

---

## 2. Matcher Tests

### 2.1 ALL_KEYS

| Key | Expected |
|-----|----------|
| `"any_key"` | `true` |
| `""` | `true` |
| `"123"` | `true` |

### 2.2 WHITELIST

**Config:** `whitelist = ["aaa", "bbb", "ccc"]`

| Key/Attribute | Expected |
|---------------|----------|
| `"aaa"` | `true` |
| `"bbb"` | `true` |
| `"ddd"` | `false` |
| `""` | `false` |

### 2.3 IN_SEGMENT

**Config:** `segment "beta_users" = ["user1", "user2", "user3"]`

| Key | Expected |
|-----|----------|
| `"user1"` | `true` |
| `"user2"` | `true` |
| `"user99"` | `false` |

### 2.4 EQUAL_TO (NUMBER)

**Config:** `value = 100`

| Attribute Value | Expected |
|-----------------|----------|
| `100` | `true` |
| `100.0` | `true` |
| `99` | `false` |
| `101` | `false` |

### 2.5 EQUAL_TO (DATETIME)

**Config:** `value = 960293532000` (milliseconds)

Note: SDK receives seconds, server stores milliseconds. Normalize by zeroing time components.

| Attribute (seconds) | Expected |
|---------------------|----------|
| `960293532` | `true` |
| `1275782400` | `false` |

### 2.6 GREATER_THAN_OR_EQUAL_TO

**Config:** `value = 100`

| Attribute | Expected |
|-----------|----------|
| `100` | `true` |
| `500` | `true` |
| `99` | `false` |
| `50` | `false` |

### 2.7 LESS_THAN_OR_EQUAL_TO

**Config:** `value = 100`

| Attribute | Expected |
|-----------|----------|
| `100` | `true` |
| `50` | `true` |
| `101` | `false` |
| `500` | `false` |

### 2.8 BETWEEN (NUMBER)

**Config:** `start = 100, end = 500`

| Attribute | Expected |
|-----------|----------|
| `100` | `true` |
| `500` | `true` |
| `250` | `true` |
| `99` | `false` |
| `501` | `false` |

### 2.9 BETWEEN (DATETIME)

**Config:** `start = 960293532000, end = 1275782400000`

| Attribute (seconds) | Expected |
|---------------------|----------|
| `980293532` | `true` |
| `900293532` | `false` |
| `1375782400` | `false` |

### 2.10 STARTS_WITH

**Config:** `prefixes = ["abc", "def", "ghi"]`

| Attribute | Expected |
|-----------|----------|
| `"abcxyz"` | `true` |
| `"defxyz"` | `true` |
| `"ghixyz"` | `true` |
| `"xyzabc"` | `false` |
| `"zzz"` | `false` |
| `""` | `false` |

### 2.11 ENDS_WITH

**Config:** `suffixes = ["abc", "def", "ghi"]`

| Attribute | Expected |
|-----------|----------|
| `"xyzabc"` | `true` |
| `"xyzdef"` | `true` |
| `"abcxyz"` | `false` |
| `""` | `false` |

### 2.12 CONTAINS_STRING

**Config:** `substrings = ["abc", "def"]`

| Attribute | Expected |
|-----------|----------|
| `"xyzabcxyz"` | `true` |
| `"xyzdefxyz"` | `true` |
| `"abcdef"` | `true` |
| `"xyz"` | `false` |

### 2.13 MATCHES_STRING (Regex)

**Test Data (sample from regex.txt):**

| Pattern | Input | Expected |
|---------|-------|----------|
| `abc` | `"abc"` | `true` |
| `abc` | `"zabcd"` | `true` |
| `abc` | `"bc"` | `false` |
| `^abc` | `"abc"` | `true` |
| `^abc` | `"zabcabc"` | `false` |
| `abc$` | `"abcabc"` | `true` |
| `^[a-z0-9_-]{3,16}$` | `"my-us3r_n4m3"` | `true` |
| `^\d+$` | `"123"` | `true` |
| `^\d+$` | `"-10"` | `false` |
| `^([a-z0-9_\.-]+)@([\da-z\.-]+)\.([a-z\.]{2,6})$` | `"john@doe.com"` | `true` |
| `^(?:(?:25[0-5]\|2[0-4][0-9]\|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]\|2[0-4][0-9]\|[01]?[0-9][0-9]?)$` | `"73.60.124.136"` | `true` |

Full dataset: 145 patterns in `testdata/regex.txt`

### 2.14 EQUAL_TO_BOOLEAN

**Config:** `value = true`

| Attribute | Type | Expected |
|-----------|------|----------|
| `true` | bool | `true` |
| `false` | bool | `false` |
| `"true"` | string | `true` |
| `"True"` | string | `true` |
| `"TRUE"` | string | `true` |
| `"tRUe"` | string | `true` |
| `"false"` | string | `false` |
| `"yes"` | string | `false` |

### 2.15 EQUAL_TO_SET

**Config:** `target = ["one", "two", "three", "four"]`

| Attribute | Expected |
|-----------|----------|
| `["one", "two", "three", "four"]` | `true` |
| `["four", "three", "two", "one"]` | `true` (order doesn't matter) |
| `["one", "two", "three"]` | `false` (subset) |
| `["one", "two", "three", "four", "five"]` | `false` (superset) |
| `[]` | `false` |

### 2.16 PART_OF_SET

**Config:** `target = ["one", "two", "three", "four"]`

| Attribute | Expected |
|-----------|----------|
| `["one", "two"]` | `true` (subset) |
| `["one", "two", "three", "four"]` | `true` (equal) |
| `["one", "two", "three", "four", "five"]` | `false` (superset) |
| `["five"]` | `false` (no intersection) |
| `[]` | `false` |

### 2.17 CONTAINS_ALL_OF_SET

**Config:** `target = ["one", "two", "three", "four"]`

| Attribute | Expected |
|-----------|----------|
| `["one", "two", "three", "four"]` | `true` (equal) |
| `["one", "two", "three", "four", "five"]` | `true` (superset) |
| `["one", "two", "three"]` | `false` (missing "four") |
| `[]` | `false` |

### 2.18 CONTAINS_ANY_OF_SET

**Config:** `target = ["one", "two", "three", "four"]`

| Attribute | Expected |
|-----------|----------|
| `["one"]` | `true` |
| `["one", "five"]` | `true` |
| `["five", "six"]` | `false` |
| `[]` | `false` |

### 2.19 LESS_THAN_OR_EQUAL_TO_SEMVER

**Test Data (from valid_semantic_versions.csv, reversed):**

| Attribute | Target | Expected |
|-----------|--------|----------|
| `"1.1.1"` | `"1.1.2"` | `true` |
| `"1.1.1"` | `"1.1.1"` | `true` |
| `"1.0.0-rc.1"` | `"1.0.0"` | `true` |
| `"1.0.0-alpha"` | `"1.0.0-beta"` | `true` |
| `"1.1.2"` | `"1.1.1"` | `false` |

### 2.20 Semver Matchers

#### EQUAL_TO_SEMVER

**Test Data (from equal_to_semver.csv):**

| Attribute | Target | Expected |
|-----------|--------|----------|
| `"1.1.1"` | `"1.1.1"` | `true` |
| `"88.88.88"` | `"88.88.88"` | `true` |
| `"1.2.3----RC-SNAPSHOT.12.9.1--.12"` | `"1.2.3----RC-SNAPSHOT.12.9.1--.12"` | `true` |
| `"00.01.002-0003.00004"` | `"0.1.2-3.4"` | `true` (normalized equal) |
| `"1.0.0"` | `"1.0.1"` | `false` |

#### GREATER_THAN_OR_EQUAL_TO_SEMVER

**Test Data (from valid_semantic_versions.csv):**

| Greater Version | Lesser Version |
|-----------------|----------------|
| `1.2.3----RC-SNAPSHOT.12.9.1--.12+788` | `1.2.3----R-S.12.9.1--.12+meta` |
| `1.1.2` | `1.1.1` |
| `1.0.0` | `1.0.0-rc.1` |
| `1.0.0-beta` | `1.0.0-alpha` |
| `2.2.2-rc.2+metadata-lalala` | `2.2.2-rc.1.2` |

#### BETWEEN_SEMVER

**Test Data (from between_semver.csv):**

| Start | Between | End |
|-------|---------|-----|
| `1.1.1` | `2.2.2` | `3.3.3` |
| `1.1.1-rc.1` | `1.1.1-rc.2` | `1.1.1-rc.3` |
| `1.0.0-alpha` | `1.0.0-alpha.1` | `1.0.0-alpha.beta` |
| `1.0.0-beta` | `1.0.0-beta.2` | `1.0.0-beta.11` |

#### IN_LIST_SEMVER

**Config:** `list = ["1.0.0-rc.1", "2.2.2-rc.1.2", "1.1.2-prerelease+meta"]`

| Attribute | Expected |
|-----------|----------|
| `"2.2.2-rc.1.2"` | `true` |
| `"1.0.0-rc.1"` | `true` |
| `"2.2.2"` | `false` |
| `"1.0.0"` | `false` |

#### Invalid Semver Strings (should fail parsing)

```
1
1.2
1.alpha.2
+invalid
-invalid
alpha
1.2.3.DEV
1.2-SNAPSHOT
-1.0.3-gamma+b7718
```

Full list: 30+ entries in `invalid_semantic_versions.csv`

### 2.21 IN_SPLIT_TREATMENT (Dependency)

**Config:**
- `dependentSplit = "feature_prereq"`
- `treatments = ["on", "enabled"]`

**Setup:** `feature_prereq` returns treatment for given key

| Key | feature_prereq Result | Expected Match |
|-----|----------------------|----------------|
| `"user1"` | `"on"` | `true` |
| `"user2"` | `"enabled"` | `true` |
| `"user3"` | `"off"` | `false` |
| `"user4"` | `"control"` | `false` |

### 2.22 Negation

All matchers support `negate: true` to invert result.

| Matcher | Input | negate=false | negate=true |
|---------|-------|--------------|-------------|
| ALL_KEYS | any | `true` | `false` |
| WHITELIST ["a"] | "a" | `true` | `false` |
| WHITELIST ["a"] | "b" | `false` | `true` |

### 2.23 IN_LARGE_SEGMENT Matcher

**Matcher Config:**
```json
{
  "matcherType": "IN_LARGE_SEGMENT",
  "userDefinedLargeSegmentMatcherData": {
    "largeSegmentName": "vip_users"
  }
}
```

**Large Segment Setup:** `vip_users` contains `["user1", "user2", "user3"]`

| Key | Expected Match |
|-----|----------------|
| `"user1"` | `true` |
| `"user2"` | `true` |
| `"user4"` | `false` |
| `"USER1"` | `false` (case sensitive) |

**Edge Cases:**
- Segment not yet synced → `false`
- Segment empty (LS_EMPTY) → `false` for all keys

### 2.24 IN_RULE_BASED_SEGMENT Matcher

**Matcher Config:**
```json
{
  "matcherType": "IN_RULE_BASED_SEGMENT",
  "userDefinedSegmentMatcherData": {
    "segmentName": "high_value"
  }
}
```

**Rule-Based Segment Setup:**
```json
{
  "name": "high_value",
  "status": "ACTIVE",
  "excluded": {
    "keys": ["blocked_user"],
    "segments": []
  },
  "conditions": [
    {
      "conditionType": "ROLLOUT",
      "matcherGroup": {
        "combiner": "AND",
        "matchers": [{
          "matcherType": "GREATER_THAN_OR_EQUAL_TO",
          "keySelector": {"attribute": "purchase_total"},
          "unaryNumericMatcherData": {"dataType": "NUMBER", "value": 1000}
        }]
      }
    }
  ]
}
```

| Key | Attributes | Expected Match |
|-----|------------|----------------|
| `"user1"` | `{"purchase_total": 1500}` | `true` |
| `"user2"` | `{"purchase_total": 500}` | `false` |
| `"blocked_user"` | `{"purchase_total": 5000}` | `false` (excluded) |

### 2.25 IN_RULE_BASED_SEGMENT with Nested Exclusions

**Rule-Based Segment Setup:**
```json
{
  "name": "premium_users",
  "excluded": {
    "keys": [],
    "segments": [
      {"name": "banned_users", "type": "standard"},
      {"name": "trial_users", "type": "rule-based"}
    ]
  },
  "conditions": [
    {"conditionType": "ROLLOUT", "matcherGroup": {"matchers": [{"matcherType": "ALL_KEYS"}]}}
  ]
}
```

**Segment Setup:**
- `banned_users` (standard): contains `["user1"]`
- `trial_users` (rule-based): matches users with `{"is_trial": true}`

| Key | Attributes | Expected Match |
|-----|------------|----------------|
| `"user1"` | `{}` | `false` (in banned_users) |
| `"user2"` | `{"is_trial": true}` | `false` (matches trial_users) |
| `"user3"` | `{"is_trial": false}` | `true` |
| `"user4"` | `{}` | `true` |

### 2.26 IN_RULE_BASED_SEGMENT Recursion Limit

**Setup:** Chain of 15 rule-based segments, each excluding the next:
- `rbs_0` excludes `rbs_1`
- `rbs_1` excludes `rbs_2`
- ... 
- `rbs_14` excludes nothing

| Segment | Depth | Expected |
|---------|-------|----------|
| `rbs_0` | 0 | Evaluates (within limit) |
| `rbs_9` | 9 | Evaluates (at limit) |
| `rbs_10` | 10 | Returns `false` (exceeds limit) |

**Max recursion depth:** 10

---

## 3. Evaluation Tests

### 3.1 Basic Evaluation

**Split:**
```json
{
  "name": "test_split",
  "killed": false,
  "defaultTreatment": "control",
  "conditions": [
    {
      "conditionType": "ROLLOUT",
      "matcherGroup": {
        "combiner": "AND",
        "matchers": [{"matcherType": "ALL_KEYS"}]
      },
      "partitions": [
        {"treatment": "on", "size": 100}
      ]
    }
  ]
}
```

| Key | Expected Treatment | Expected Label |
|-----|-------------------|----------------|
| `"any_user"` | `"on"` | `"in segment all"` |

### 3.2 Killed Split

**Split:**
```json
{
  "name": "killed_split",
  "killed": true,
  "defaultTreatment": "off",
  "conditions": [...]
}
```

| Key | Expected Treatment | Expected Label |
|-----|-------------------|----------------|
| `"any_user"` | `"off"` | `"killed"` |

### 3.3 Split Not Found

| Key | Split Name | Expected Treatment | Expected Label |
|-----|------------|-------------------|----------------|
| `"user"` | `"nonexistent"` | `"control"` | `"definition not found"` |

### 3.4 Traffic Allocation

**Split:**
```json
{
  "trafficAllocation": 50,
  "trafficAllocationSeed": 12345,
  "defaultTreatment": "off",
  "conditions": [
    {
      "conditionType": "ROLLOUT",
      "partitions": [{"treatment": "on", "size": 100}]
    }
  ]
}
```

- ~50% of users get `"on"`
- ~50% of users get `"off"` with label `"not in split"`

### 3.5 Prerequisites

**Setup:**
- `prereq_split` returns `"on"` for key `"user1"`, `"off"` for others
- Main split has `prerequisites: [{"n": "prereq_split", "ts": ["on"]}]`

| Key | Expected Treatment | Expected Label |
|-----|-------------------|----------------|
| `"user1"` | *(evaluated treatment)* | *(from matched condition)* |
| `"user2"` | `defaultTreatment` | `"prerequisites not met"` |

### 3.6 No Condition Matched

**Split with conditions that don't match:**

| Key | Expected Treatment | Expected Label |
|-----|-------------------|----------------|
| `"user"` | `defaultTreatment` | `"default rule"` |

### 3.7 Configurations

**Split:**
```json
{
  "configurations": {
    "on": "{\"color\": \"blue\", \"size\": 13}",
    "off": null
  }
}
```

| Treatment | Expected Config |
|-----------|-----------------|
| `"on"` | `{"color": "blue", "size": 13}` |
| `"off"` | `null` |

---

## 4. Impression Tests

### 4.1 Impression Structure

```json
{
  "k": "user_key",
  "b": "bucketing_key",
  "f": "feature_name",
  "t": "on",
  "r": "default rule",
  "c": 1234567890,
  "m": 1699999999999,
  "pt": 1699999998000
}
```

### 4.2 Deduplication (Optimized Mode)

**Hash Key:** `{key}:{feature}:{treatment}:{label}:{changeNumber}`
**Hash Algorithm:** Murmur3-128, take 64 LSBs
**Cache:** LRU cache mapping hash → timestamp

| Impression # | Same Hash? | Action |
|--------------|------------|--------|
| 1st | N/A | Log, pt=0 |
| 2nd (same hour) | Yes | Don't log, increment counter |
| 3rd (new hour) | Yes | Log, pt=previous_time |

### 4.3 Hour Truncation

```
truncate(timestamp_ms) = timestamp_ms - (timestamp_ms % 3600000)
```

| Timestamp | Truncated |
|-----------|-----------|
| `1699999999999` | `1699999200000` |
| `1700003599999` | `1700002800000` |

### 4.4 Modes

| Mode | Log Full Impressions | Send Counts | Track Unique Keys |
|------|---------------------|-------------|-------------------|
| `optimized` | First per hour | Yes | No |
| `debug` | All | No | No |
| `none` | None | Yes | Yes |

---

## 5. Streaming Tests

### 5.1 SSE Event Parsing

**Split Update:**
```json
{
  "data": "{\"type\":\"SPLIT_UPDATE\",\"changeNumber\":1591996685190}"
}
```

Expected: Trigger split sync with changeNumber 1591996685190

**Split Kill:**
```json
{
  "data": "{\"type\":\"SPLIT_KILL\",\"changeNumber\":123,\"splitName\":\"my_feature\",\"defaultTreatment\":\"off\"}"
}
```

Expected: Locally kill `my_feature` with treatment `off`

**Segment Update:**
```json
{
  "data": "{\"type\":\"SEGMENT_UPDATE\",\"changeNumber\":123,\"segmentName\":\"beta_users\"}"
}
```

Expected: Trigger segment sync for `beta_users`

### 5.2 Control Messages

| Control Type | Expected Action |
|--------------|-----------------|
| `STREAMING_ENABLED` | Stop polling, use streaming |
| `STREAMING_PAUSED` | Start polling, keep stream alive |
| `STREAMING_DISABLED` | Stop streaming, permanent polling |

### 5.3 Occupancy

```json
{
  "data": "{\"metrics\":{\"publishers\":0}}"
}
```

When all control channels have 0 publishers → fall back to polling

### 5.4 Optimistic Updates

**Config:**
```json
{
  "type": "SPLIT_UPDATE",
  "changeNumber": 124,
  "pcn": 123,
  "c": 0,
  "d": "eyJuYW1lIjoi..."
}
```

| Local ChangeNumber | Action |
|--------------------|--------|
| 123 | Apply `d` directly (base64 decode) |
| 122 | Fetch from API (missed update) |
| 124 | Ignore (already have) |

### 5.5 Compression

| `c` value | Compression |
|-----------|-------------|
| 0 | None |
| 1 | gzip |
| 2 | zlib |

---

## 6. Sync Tests

### 6.1 Change Number Protocol

**Request:** `GET /splitChanges?since=123`

**Response:**
```json
{
  "splits": [...],
  "since": 123,
  "till": 456
}
```

| since | till | Action |
|-------|------|--------|
| 123 | 456 | More changes, fetch again with since=456 |
| 456 | 456 | Fully synced |

### 6.2 Segment Sync

Only fetch segments referenced in active splits.

### 6.3 Large Segment Sync

**Request:** `GET /largeSegmentDefinition/{name}?since={changeNumber}`

**Response (LS_NEW_DEFINITION):**
```json
{
  "n": "vip_users",
  "t": "LS_NEW_DEFINITION",
  "v": "1.0",
  "cn": 1234567890,
  "rfd": {
    "d": {"f": 1, "k": 3, "s": 30, "e": 9999999999999},
    "p": {"m": "GET", "u": "https://example.com/file.csv", "h": {}}
  }
}
```

**CSV File Content:**
```
user1
user2
user3
```

| Test Case | Expected |
|-----------|----------|
| Initial sync (since=-1) | Fetch RFD, download CSV, store 3 keys |
| since >= cn | HTTP 304, no download |
| Expired URL (e < now) | Retry with fresh fetch |
| Empty segment (t=LS_EMPTY) | Clear all keys, set cn |

### 6.3.1 CSV Parsing Edge Cases

**CSV Content:**
```
user1
  user2  
user3,extra

user4
```

| Line | Parsed Key | Notes |
|------|------------|-------|
| `user1` | `"user1"` | Normal |
| `  user2  ` | `"user2"` | Whitespace trimmed |
| `user3,extra` | (skipped) | Malformed, log warning |
| (empty) | (skipped) | Empty line |
| `user4` | `"user4"` | Normal |

**Result:** 3 keys stored: `["user1", "user2", "user4"]`

**BOM handling:** If file starts with `0xEF 0xBB 0xBF`, strip before parsing.

### 6.4 Large Segment SSE Update

**SSE Message:**
```json
{
  "type": "LS_DEFINITION_UPDATE",
  "ls": [{
    "n": "vip_users",
    "t": "LS_NEW_DEFINITION",
    "cn": 1234567891,
    "rfd": {...}
  }]
}
```

| Local cn | Notification cn | Action |
|----------|-----------------|--------|
| 1234567890 | 1234567891 | Download new file |
| 1234567891 | 1234567891 | Ignore (already have) |
| 1234567890 | 1234567893 | Download (missed one, ok) |

### 6.5 Rule-Based Segment Sync

Rule-based segments sync as part of splitChanges:

**Request:** `GET /splitChanges?since={cn}&s=1.3`

**Response:**
```json
{
  "splits": [...],
  "since": 100,
  "till": 200,
  "ruleBasedSegments": {
    "d": [
      {
        "changeNumber": 150,
        "name": "high_value",
        "status": "ACTIVE",
        "excluded": {"keys": [], "segments": []},
        "conditions": [...]
      }
    ],
    "t": 200,
    "s": 100
  }
}
```

| status | Action |
|--------|--------|
| ACTIVE | Add/update segment |
| ARCHIVED | Remove segment |

### 6.6 Rule-Based Segment SSE Update

**SSE Message:**
```json
{
  "type": "RB_SEGMENT_UPDATE",
  "changeNumber": 200,
  "pcn": 150,
  "d": "eyJuYW1lIjoi..."
}
```

| Local cn | pcn | Action |
|----------|-----|--------|
| 150 | 150 | Apply directly |
| 149 | 150 | Fetch from API |
| 200 | 150 | Ignore (already have) |

---

## 7. Input Validation

### 7.1 Flag Set Names

**Valid:** `^[a-z0-9][_a-z0-9]{0,49}$`

| Input | Valid? |
|-------|--------|
| `"my_set"` | Yes |
| `"set1"` | Yes |
| `"_set"` | No (must start with alphanumeric) |
| `"SET"` | No (lowercase only) |
| `"my-set"` | No (no hyphens) |
| `"a"` + 50 chars | No (max 50) |

### 7.2 Missing Attributes

When matcher requires attribute but not provided:
- Log warning
- Return `false` (no match)

### 7.3 Type Mismatch

When attribute type doesn't match matcher expectation:
- Log error
- Return `false` (no match)

---

## 8. Test Fixtures

### 8.1 Split Definition

```json
{
  "name": "test_split",
  "trafficTypeName": "user",
  "trafficAllocation": 100,
  "trafficAllocationSeed": -1364119282,
  "seed": -605938843,
  "status": "ACTIVE",
  "killed": false,
  "defaultTreatment": "off",
  "changeNumber": 1660326991072,
  "algo": 2,
  "configurations": {
    "on": "{\"color\":\"blue\"}"
  },
  "sets": ["set1", "set2"],
  "conditions": [
    {
      "conditionType": "WHITELIST",
      "matcherGroup": {
        "combiner": "AND",
        "matchers": [
          {
            "matcherType": "WHITELIST",
            "negate": false,
            "whitelistMatcherData": {
              "whitelist": ["admin", "test_user"]
            }
          }
        ]
      },
      "partitions": [{"treatment": "on", "size": 100}],
      "label": "whitelisted"
    },
    {
      "conditionType": "ROLLOUT",
      "matcherGroup": {
        "combiner": "AND",
        "matchers": [
          {
            "matcherType": "ALL_KEYS",
            "negate": false
          }
        ]
      },
      "partitions": [
        {"treatment": "on", "size": 50},
        {"treatment": "off", "size": 50}
      ],
      "label": "default rule"
    }
  ]
}
```

### 8.2 Segment Definition

```json
{
  "name": "beta_users",
  "added": ["user1", "user2", "user3"],
  "removed": [],
  "since": -1,
  "till": 1489542661161
}
```

### 8.3 SSE Event

```json
{
  "id": "event_id",
  "clientId": "client_123",
  "timestamp": 1591988399435,
  "encoding": "json",
  "channel": "org_env_splits",
  "data": "{\"type\":\"SPLIT_UPDATE\",\"changeNumber\":123}"
}
```

---

## 9. Test Data Files

| File | Purpose | Format |
|------|---------|--------|
| `expected-treatments.csv` | Hash consistency (1264 entries) | `key,treatment` |
| `valid_semantic_versions.csv` | Semver ordering | `greater,lesser` |
| `invalid_semantic_versions.csv` | Invalid semver strings | one per line |
| `equal_to_semver.csv` | Semver equality | `v1,v2` |
| `between_semver.csv` | Semver ranges | `start,middle,end` |
| `regex.txt` | Regex patterns (145 entries) | `pattern#input#expected` |

---

## 10. Client API Tests

### 10.1 get_treatment

| Key | Split | Attributes | Expected Treatment |
|-----|-------|------------|-------------------|
| `"user1"` | `"test_split"` | `{}` | `"on"` or `"off"` (based on bucket) |
| `"admin"` | `"test_split"` | `{}` | `"on"` (whitelisted) |
| `"user1"` | `"nonexistent"` | `{}` | `"control"` |

### 10.2 get_treatment_with_config

| Key | Split | Treatment | Config |
|-----|-------|-----------|--------|
| `"admin"` | `"test_split"` | `"on"` | `{"color": "blue"}` |
| `"user1"` | `"test_split"` | `"off"` | `null` |

### 10.3 get_treatments (bulk)

**Input:** `key="user1", splits=["split_a", "split_b", "nonexistent"]`

**Output:**
```json
{
  "split_a": "on",
  "split_b": "off",
  "nonexistent": "control"
}
```

### 10.4 get_treatments_by_flag_set

**Setup:** `flag_set "mobile" = ["feature_a", "feature_b"]`

| Key | Flag Set | Expected |
|-----|----------|----------|
| `"user1"` | `"mobile"` | `{"feature_a": "on", "feature_b": "off"}` |
| `"user1"` | `"nonexistent"` | `{}` |

### 10.5 block_until_ready

| Timeout | SDK State | Expected |
|---------|-----------|----------|
| 5000ms | Ready in 1000ms | Returns immediately after ready |
| 500ms | Ready in 1000ms | Timeout error |

### 10.6 destroy

After `destroy()`:
- All evaluations return `"control"`
- No impressions/events sent
- Background tasks stopped

---

## 11. Track API Tests

### 11.1 Basic Event

```
track("user1", "user", "purchase", 99.99, {"item": "widget"})
```

**Expected event queued:**
```json
{
  "key": "user1",
  "trafficTypeName": "user",
  "eventTypeId": "purchase",
  "value": 99.99,
  "properties": {"item": "widget"},
  "timestamp": <now_ms>
}
```

### 11.2 Event without value/properties

```
track("user1", "user", "page_view")
```

**Expected:** Event queued with `value=null`, `properties=null`

### 11.3 Property Limits

| Properties Size | Expected |
|-----------------|----------|
| < 300 bytes | Queued |
| > 300 bytes | Truncated or rejected (impl-specific) |
| > 300 properties | Truncated or rejected |

### 11.4 Queue Full

When queue size (10,000) is reached:
- New events dropped
- Telemetry: `EventsDropped` incremented

---

## 12. Manager API Tests

### 12.1 splits()

Returns list of SplitView for all active splits.

**SplitView structure:**
```json
{
  "name": "test_split",
  "trafficType": "user",
  "killed": false,
  "treatments": ["on", "off"],
  "changeNumber": 123,
  "configs": {"on": "{...}", "off": null},
  "sets": ["frontend"],
  "defaultTreatment": "off"
}
```

### 12.2 split(name)

| Name | Expected |
|------|----------|
| `"test_split"` | SplitView object |
| `"nonexistent"` | `null` |

### 12.3 split_names()

Returns: `["split_a", "split_b", "split_c"]` (sorted or unsorted, impl-specific)

---

## 13. Localhost Mode Tests

### 13.1 YAML Parsing

**File: splits.yaml**
```yaml
- my_feature:
    treatment: "on"

- another_feature:
    treatment: "off"
    config: '{"color": "red"}'

- whitelisted_feature:
    treatment: "beta"
    keys:
      - admin
      - test_user
```

| Key | Split | Expected Treatment |
|-----|-------|-------------------|
| `"anyone"` | `"my_feature"` | `"on"` |
| `"admin"` | `"whitelisted_feature"` | `"beta"` |
| `"random"` | `"whitelisted_feature"` | `"control"` (no match) |

### 13.2 Multiple Conditions

**File:**
```yaml
- feature:
    treatment: "vip"
    keys: ["admin"]

- feature:
    treatment: "standard"
```

| Key | Expected |
|-----|----------|
| `"admin"` | `"vip"` (whitelist first) |
| `"user"` | `"standard"` (rollout) |

### 13.3 File Change Detection

1. Initial load: `my_feature: on`
2. Modify file: `my_feature: off`
3. After refresh period: `get_treatment` returns `"off"`

### 13.4 Sanitization

**Invalid file:**
```json
{
  "ff": {
    "d": [{
      "name": "test",
      "trafficAllocation": 150,
      "seed": 0,
      "status": "INVALID"
    }]
  }
}
```

**Sanitized to:**
- `trafficAllocation`: 100
- `seed`: random value
- `status`: "ACTIVE"

---

## 14. Readiness Tests

### 14.1 Ready After Sync

| Scenario | is_ready() |
|----------|------------|
| Before initial sync | `false` |
| After splits + segments fetched | `true` |
| After streaming connected | `true` |

### 14.2 block_until_ready Behavior

| Timeout | Sync Time | Result |
|---------|-----------|--------|
| 10s | 2s | Success after 2s |
| 2s | 10s | Timeout error after 2s |

---

## 15. Implementation Checklist

### Core (required for MVP)

- [ ] Murmur3 hash (32-bit, with seed)
- [ ] Legacy hash (Java polynomial)
- [ ] Bucket calculation: `abs(hash % 100) + 1`
- [ ] Treatment selection from partitions

### Matchers (26 types)

- [ ] ALL_KEYS
- [ ] WHITELIST
- [ ] IN_SEGMENT
- [ ] IN_LARGE_SEGMENT
- [ ] IN_RULE_BASED_SEGMENT
- [ ] EQUAL_TO (number)
- [ ] EQUAL_TO (datetime)
- [ ] GREATER_THAN_OR_EQUAL_TO
- [ ] LESS_THAN_OR_EQUAL_TO
- [ ] BETWEEN (number)
- [ ] BETWEEN (datetime)
- [ ] STARTS_WITH
- [ ] ENDS_WITH
- [ ] CONTAINS_STRING
- [ ] MATCHES_STRING (regex)
- [ ] EQUAL_TO_BOOLEAN
- [ ] EQUAL_TO_SET
- [ ] PART_OF_SET
- [ ] CONTAINS_ALL_OF_SET
- [ ] CONTAINS_ANY_OF_SET
- [ ] EQUAL_TO_SEMVER
- [ ] GREATER_THAN_OR_EQUAL_TO_SEMVER
- [ ] LESS_THAN_OR_EQUAL_TO_SEMVER
- [ ] BETWEEN_SEMVER
- [ ] IN_LIST_SEMVER
- [ ] IN_SPLIT_TREATMENT

### Evaluation

- [ ] Killed split handling
- [ ] Traffic allocation
- [ ] Prerequisites
- [ ] Condition ordering (whitelist first)
- [ ] Default treatment fallback
- [ ] Label generation

### Impressions

- [ ] Optimized mode deduplication
- [ ] Debug mode (all impressions)
- [ ] None mode (counts only)
- [ ] Hour truncation
- [ ] LRU cache for dedup

### Sync

- [ ] Change number protocol
- [ ] SSE parsing
- [ ] Optimistic updates
- [ ] Compression (gzip, zlib)
- [ ] Control messages
- [ ] Occupancy tracking

### Large Segments (Spec v1.2)

- [ ] Fetch RFD metadata
- [ ] Download CSV file
- [ ] Parse single-column CSV
- [ ] CSV edge cases (empty lines, whitespace, BOM, malformed)
- [ ] Handle LS_NEW_DEFINITION
- [ ] Handle LS_EMPTY
- [ ] URL expiration retry
- [ ] Exponential backoff (10s base, 60s max, 5 attempts)
- [ ] CDN bypass on retry exhaustion
- [ ] SSE LS_DEFINITION_UPDATE
- [ ] Concurrent download limiting (max 5)

### Rule-Based Segments (Spec v1.3)

- [ ] Parse rule-based segment definition
- [ ] Explicit key exclusions
- [ ] Standard segment exclusions
- [ ] Rule-based segment exclusions (nested)
- [ ] Large segment exclusions
- [ ] Condition evaluation
- [ ] Recursion depth limit (max 10)
- [ ] SSE RB_SEGMENT_UPDATE
- [ ] Optimistic updates with pcn

### Validation

- [ ] Flag set name validation
- [ ] Missing attribute handling
- [ ] Type mismatch handling

### Client API

- [ ] get_treatment
- [ ] get_treatment_with_config
- [ ] get_treatments
- [ ] get_treatments_with_config
- [ ] get_treatments_by_flag_set
- [ ] get_treatments_by_flag_sets
- [ ] track
- [ ] block_until_ready
- [ ] destroy

### Manager API

- [ ] splits
- [ ] split
- [ ] split_names

### Localhost Mode

- [ ] YAML parsing
- [ ] JSON parsing
- [ ] Multiple conditions ordering
- [ ] File change detection
- [ ] Sanitization
