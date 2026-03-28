-- alias_policy.lua
-- Rspamd prefilter module that enforces mailing list sending policies
-- for Mailcow aliases. Policies are defined in the alias's private_comment
-- field and synced from the Mailcow API.
--
-- Architecture:
--   - The primary controller worker fetches aliases from the Mailcow API
--     on a periodic timer and writes the result to a JSON policy file.
--   - All workers (including scanners) use rspamd's map subsystem to
--     monitor the policy file. When it changes, the map callback parses
--     the new content and rebuilds the in-memory policy table.
--   - This means exactly one API call per sync interval, regardless of
--     how many workers are running.

-- Rspamd modules
local rspamd_logger = require("rspamd_logger")
local rspamd_http = require("rspamd_http")
local ucl = require("ucl")

-- Module name for config lookups
local N = "alias_policy"

-- Configuration (populated from rspamd config block)
local settings = {
  api_key = nil,
  hostname = nil,
  sync_interval = 300,           -- seconds between API syncs
  policy_file = "/etc/rspamd/local.d/list_policies.json",  -- policy file watched by map
}

-- Valid policy values
local valid_policies = {
  public = true,
  domain = true,
  membersonly = true,
  moderatorsonly = true,
  membersandmoderatorsonly = true,
}

-- In-memory policy table (address -> policy data)
local policies = {}

-- Converts an array of strings into a lookup set (lowercase keys).
local function list_to_set(list)
  local set = {}
  if list then
    for _, v in ipairs(list) do
      set[v:lower()] = true
    end
  end
  return set
end

-- Split a string by a delimiter, returning a table of parts.
local function split(str, sep)
  local parts = {}
  if not str or str == "" then return parts end
  for part in str:gmatch("([^" .. sep .. "]+)") do
    parts[#parts + 1] = part
  end
  return parts
end

-- Trim leading/trailing whitespace from a string.
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-------------------------------------------------------------------
-- Map callback: called by rspamd's map subsystem whenever the
-- policy file changes. Parses the UCL/JSON content and rebuilds
-- the in-memory policies table. Runs in every worker.
-------------------------------------------------------------------
local function on_policy_map_load(data)
  if not data or #data == 0 then
    rspamd_logger.errx(rspamd_config, "%s: map callback received empty data", N)
    return
  end

  local parser = ucl.parser()
  local ok, err = parser:parse_string(data)
  if not ok then
    rspamd_logger.errx(rspamd_config, "%s: failed to parse policy data: %s", N, err)
    return
  end
  local raw = parser:get_object()

  local new_policies = {}
  local count = 0
  for list_addr, val in pairs(raw) do
    new_policies[list_addr:lower()] = {
      policy = val.policy,
      members = list_to_set(val.members),
      moderators = list_to_set(val.moderators),
    }
    count = count + 1
  end

  policies = new_policies
  rspamd_logger.errx(rspamd_config, "%s: loaded %s policies from map", N, count)
end

-------------------------------------------------------------------
-- API sync: fetches aliases from the Mailcow API, parses them,
-- and writes the policy file. Only called from the primary
-- controller worker.
-------------------------------------------------------------------

-- Parse raw API response (Lua table from JSON) into a policy map
-- suitable for writing to the policy file.
-- Returns output table and count, or nil and error message.
local function parse_aliases(cfg, aliases)
  if type(aliases) ~= "table" then
    return nil, "expected array of aliases"
  end

  rspamd_logger.errx(cfg, "%s: parse_aliases: got %d items", N, #aliases)

  local output = {}
  local count = 0

  for _, alias in ipairs(aliases) do
    rspamd_logger.errx(cfg, "%s: DEBUG: alias.address=%s, active=%s (%s), tonumber=%s", 
      N, tostring(alias.address), tostring(alias.active), type(alias.active), tostring(tonumber(alias.active)))
    if tonumber(alias.active) == 1 then
      local address = (alias.address or ""):lower()
      if address ~= "" then
        rspamd_logger.errx(cfg, "%s: DEBUG: processing alias %s, private_comment=%s (%s)", 
          N, address, tostring(alias.private_comment), type(alias.private_comment))
        local raw_comment = (alias.private_comment or ""):lower()
        local parts = split(raw_comment, "::")
        local policy_name = trim(parts[1] or "")

        if not valid_policies[policy_name] then
          policy_name = "public"
        end

        -- Members from goto field (comma-separated)
        local members = {}
        local goto_str = alias["goto"] or ""
        if goto_str ~= "" then
          for _, addr in ipairs(split(goto_str, ",")) do
            local cleaned = trim(addr):lower()
            if cleaned ~= "" then
              members[#members + 1] = cleaned
            end
          end
        end

        -- Moderators from after :: in private_comment
        local moderators = {}
        if #parts > 1 then
          local mod_str = parts[2] or ""
          for _, addr in ipairs(split(mod_str, ",")) do
            local cleaned = trim(addr):lower()
            if cleaned ~= "" then
              moderators[#moderators + 1] = cleaned
            end
          end
        end

        output[address] = {
          policy = policy_name,
          members = members,
          moderators = moderators,
        }
        count = count + 1
      end
    end
  end

  return output, count
end

-- Write policy table to disk (atomic write via tmp + rename).
local function save_policy_file(policy_data)
  local json_str = ucl.to_json(policy_data, true)
  if not json_str then
    rspamd_logger.errx(rspamd_config, "%s: failed to serialize policies", N)
    return
  end

  local tmp_path = settings.policy_file .. ".tmp"
  local f = io.open(tmp_path, "w")
  if not f then
    rspamd_logger.errx(rspamd_config, "%s: cannot write to %s", N, tmp_path)
    return
  end
  f:write(json_str)
  f:close()
  os.rename(tmp_path, settings.policy_file)
  rspamd_logger.errx(rspamd_config, "%s: wrote policy file %s", N, settings.policy_file)
end

-- Fetch aliases from Mailcow API and write the policy file.
local function sync_from_api(cfg, ev_base)
  if not settings.api_key or not settings.hostname then
    rspamd_logger.errx(rspamd_config, "%s: api_key or hostname not configured, skipping sync", N)
    return
  end

  local url = string.format("https://%s/api/v1/get/alias/all", settings.hostname)

  rspamd_http.request({
    config = cfg,
    ev_base = ev_base,
    url = url,
    method = "GET",
    headers = {
      ["accept"] = "application/json",
      ["X-API-Key"] = settings.api_key,
    },
    timeout = 30.0,
    callback = function(err_message, code, body, _headers)
      if err_message then
        rspamd_logger.errx(rspamd_config, "%s: API request failed: %s", N, err_message)
        return
      end

      if code ~= 200 then
        rspamd_logger.errx(rspamd_config, "%s: API returned HTTP %s", N, code)
        return
      end

      -- Convert rspamd_text to Lua string (tostring() may not work correctly)
      local body_str
      if type(body) == "userdata" and body.str then
        body_str = body:str()
      else
        body_str = tostring(body)
      end
      if not body_str or #body_str == 0 then
        rspamd_logger.errx(rspamd_config, "%s: API returned empty body", N)
        return
      end

      rspamd_logger.errx(rspamd_config, "%s: received API response (%s bytes)", N, #body_str)

      -- Parse JSON response and process aliases
      local ok, err = pcall(function()
        local parser = ucl.parser()
        local parse_ok, parse_err = parser:parse_string(body_str)
        if not parse_ok then
          rspamd_logger.errx(rspamd_config, "%s: failed to parse API response: %s", N, parse_err)
          return
        end

        local wrapped = parser:get_object_wrapped()
        if not wrapped then
          rspamd_logger.errx(rspamd_config, "%s: UCL parsed to nil", N)
          return
        end

        -- Convert wrapped UCL object to JSON string, then re-parse to get native Lua tables
        local json_str = wrapped:tostring("json-compact")
        local parser2 = ucl.parser()
        local ok2, err2 = parser2:parse_string(json_str)
        if not ok2 then
          rspamd_logger.errx(rspamd_config, "%s: failed to re-parse JSON: %s", N, err2)
          return
        end
        local aliases = parser2:get_object()

        -- Normalize: single object -> array
        if aliases[1] == nil and aliases.address then
          aliases = { aliases }
        end

        local policy_data, count = parse_aliases(rspamd_config, aliases)
        if not policy_data then
          rspamd_logger.errx(rspamd_config, "%s: failed to process aliases: %s", N, count)
          return
        end

        rspamd_logger.errx(rspamd_config, "%s: parsed %s policies from API", N, count)
        save_policy_file(policy_data)
      end)
      if not ok then
        rspamd_logger.errx(rspamd_config, "%s: error processing API response: %s", N, tostring(err))
      end
    end,
  })
end

-------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------
local opts = rspamd_config:get_all_opt(N)
if opts then
  if opts.api_key then
    settings.api_key = opts.api_key
  end
  if opts.hostname then
    settings.hostname = opts.hostname
  end
  if opts.sync_interval then
    settings.sync_interval = tonumber(opts.sync_interval) or settings.sync_interval
  end
  if opts.policy_file then
    settings.policy_file = opts.policy_file
  end
end

if not settings.api_key or not settings.hostname then
  rspamd_logger.errx(rspamd_config,
    "%s: missing required config (api_key and hostname must be set in alias_policy {} block)", N)
end

-------------------------------------------------------------------
-- Map registration: all workers watch the policy file via the map
-- subsystem. The master process monitors the file (inotify/ev_stat)
-- and pushes content to workers when it changes.
-------------------------------------------------------------------
local policy_map = rspamd_config:add_map({
  type = "callback",
  url = "file://" .. settings.policy_file,
  description = "Alias sending policy map (JSON)",
  callback = on_policy_map_load,
})

if not policy_map then
  rspamd_logger.errx(rspamd_config, "%s: failed to register policy map for %s", N, settings.policy_file)
end

-------------------------------------------------------------------
-- Periodic API sync: only the primary controller fetches from
-- the API and writes the file. Scanner workers just read via map.
-------------------------------------------------------------------
rspamd_config:add_on_load(function(cfg, ev_base, worker)
  if worker:get_type() ~= 'controller' then
    rspamd_logger.errx(rspamd_config, "%s: worker is not primary controller, skipping API sync setup", N)
    return
  end

  rspamd_logger.errx(rspamd_config, "%s: primary controller starting API sync (interval=%ss)", N, settings.sync_interval)

  -- First sync immediately
  sync_from_api(cfg, ev_base)

  -- Schedule periodic syncs
  rspamd_config:add_periodic(ev_base, settings.sync_interval, function(periodic_cfg, periodic_ev_base)
    sync_from_api(periodic_cfg, periodic_ev_base)
    return true
  end)
end)

-------------------------------------------------------------------
-- Prefilter: policy enforcement on incoming messages
-------------------------------------------------------------------

local function reject(task, sender, list_addr, msg)
  rspamd_logger.errx(task, "%s: REJECT %s -> %s (%s)", N, sender, list_addr, msg)
  task:insert_result("ALIAS_POLICY", 1.0, list_addr)
  task:set_pre_result("reject", msg, N)
  return true
end

local function check_policy(task)
  if not next(policies) then
    return
  end

  local sender = task:get_from("smtp")
  local rcpts = task:get_recipients("smtp")
  if not sender or not rcpts then
    return
  end
  sender = sender[1].addr:lower()
  local sender_domain = sender:match("@(.+)")

  for _, rcpt in ipairs(rcpts) do
    local list_addr = rcpt.addr:lower()
    local list = policies[list_addr]
    if list then
      local policy = list.policy
      rspamd_logger.errx(task, "%s: checking %s -> %s (policy=%s)", N, sender, list_addr, policy)

      if policy == "public" then
        rspamd_logger.errx(task, "%s: ALLOW %s -> %s (public)", N, sender, list_addr)
        break
      elseif policy == "domain" then
        local list_domain = list_addr:match("@(.+)")
        if sender_domain ~= list_domain then
          reject(task, sender, list_addr, "Sender not in same domain")
          return
        else
          rspamd_logger.errx(task, "%s: ALLOW %s -> %s (domain match)", N, sender, list_addr)
        end
      elseif policy == "membersonly" then
        if not list.members[sender] then
          reject(task, sender, list_addr, "Sender not a member")
          return
        else
          rspamd_logger.errx(task, "%s: ALLOW %s -> %s (member)", N, sender, list_addr)
        end
      elseif policy == "moderatorsonly" then
        if not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a moderator")
          return
        else
          rspamd_logger.errx(task, "%s: ALLOW %s -> %s (moderator)", N, sender, list_addr)
        end
      elseif policy == "membersandmoderatorsonly" then
        if not list.members[sender] and not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a member or moderator")
          return
        else
          rspamd_logger.errx(task, "%s: ALLOW %s -> %s (member/moderator)", N, sender, list_addr)
        end
      else
        rspamd_logger.errx(task, "%s: unknown policy '%s' for %s, defaulting to allow", N, policy, list_addr)
      end
    end
  end
end

rspamd_config:register_symbol({
  name = "ALIAS_POLICY",
  type = "prefilter",
  priority = 10,
  callback = check_policy,
})
