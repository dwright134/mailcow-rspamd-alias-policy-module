# Plan: Refactor alias_policy.lua to use rspamd callback map

## Goal
Replace manual file I/O polling (every 60s per worker) with rspamd's built-in
map subsystem, which monitors the file via inotify in the master process and
delivers updated content to workers without blocking.

## Changes to alias_policy.lua

### 1. Remove manual file I/O infrastructure
- Remove `last_load` and `cache_ttl` variables (lines 13-14)
- Remove the entire `load_policies()` function (lines 32-66)
- Remove the `load_policies()` init call (line 69)
- Remove the `load_policies()` call inside `check_policy()` (line 89)

### 2. Add callback map registration
Register a callback map at module scope:
```lua
local function on_policy_map_load(data)
  -- Parse data with UCL, rebuild policies table
end

local policy_map = rspamd_config:add_map({
  type = "callback",
  url = "file://" .. policy_file,
  description = "Alias sending policy map (JSON)",
  callback = on_policy_map_load,
})
```

### 3. Move parsing logic into callback
The `on_policy_map_load` function receives raw file content as a string
parameter. It will:
- Guard against nil/empty data
- Parse with UCL (same as before)
- Rebuild policies into a new table, then swap atomically
- Log the count

### 4. Add guard in check_policy()
Replace the `load_policies()` call with:
```lua
if not next(policies) then
  return  -- map not loaded yet, fail-open
end
```

### 5. Fix syntax error on lines 154-155
The current code has a stray comma:
```lua
 rspamd_config:register_symbol({
, name = "ALIAS_POLICY",
```
Fix to:
```lua
rspamd_config:register_symbol({
  name = "ALIAS_POLICY",
```

## Kept unchanged
- `list_to_set()` helper
- `reject()` helper
- All policy checking logic in `check_policy()`
- `ucl` require (still needed for parsing in the callback)
- `rspamd_logger` require
