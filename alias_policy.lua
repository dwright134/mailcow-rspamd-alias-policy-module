-- alias_policy.lua
-- Rspamd prefilter module that enforces mailing list sending policies
-- for Mailcow aliases. Policies are defined in the alias's private_comment
-- field and synced from the Mailcow API.
--
-- The module uses rspamd_http to fetch aliases directly from the Mailcow
-- API on a periodic timer (add_periodic), eliminating the need for external
-- shell scripts, cron jobs, or background processes. Policy data is kept
-- entirely in memory.
--
-- On cold start, the module loads any existing policy file from disk as a
-- bootstrap cache. Once the first HTTP sync completes, the in-memory table
-- is authoritative and the file is updated as a backup for future restarts.

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
  policy_file = "/etc/rspamd/list_policies.json",  -- disk cache for cold starts
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

-- Parse raw API response (Lua table from JSON) into the policies table.
-- Returns new_policies table and count, or nil and error message.
local function parse_aliases(aliases)
  if type(aliases) ~= "table" then
    return nil, "expected array of aliases"
  end

  local new_policies = {}
  local count = 0

  for _, alias in ipairs(aliases) do
    -- Only process active aliases
    if alias.active == 1 then
      local address = (alias.address or ""):lower()
      if address ~= "" then
        local raw_comment = (alias.private_comment or ""):lower()
        local parts = split(raw_comment, "::")
        local policy_name = trim(parts[1] or "")

        -- Default to public if policy is unrecognized or empty
        if not valid_policies[policy_name] then
          policy_name = "public"
        end

        -- Parse members from goto field (comma-separated)
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

        -- Parse moderators from the part after :: in private_comment
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

        new_policies[address] = {
          policy = policy_name,
          members = list_to_set(members),
          moderators = list_to_set(moderators),
        }
        count = count + 1
      end
    end
  end

  return new_policies, count
end

-- Load policies from the disk cache file (cold start bootstrap).
local function load_policy_file()
  local f = io.open(settings.policy_file, "r")
  if not f then
    rspamd_logger.infox(rspamd_config, "%s: no policy cache file at %s, starting empty",
      N, settings.policy_file)
    return
  end

  local data = f:read("*a")
  f:close()

  if not data or #data == 0 then
    rspamd_logger.warnx(rspamd_config, "%s: policy cache file is empty", N)
    return
  end

  local parser = ucl.parser()
  local ok, err = parser:parse_string(data)
  if not ok then
    rspamd_logger.errx(rspamd_config, "%s: failed to parse policy cache: %s", N, err)
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
  rspamd_logger.infox(rspamd_config, "%s: loaded %s policies from cache file", N, count)
end

-- Write current policies to disk cache for future cold starts.
-- Serializes the in-memory policies table to the same JSON format
-- that the old shell script produced, so the cache file is compatible.
local function save_policy_file(new_policies)
  -- Build a UCL-compatible table for serialization
  local output = {}
  for addr, pol in pairs(new_policies) do
    local members_list = {}
    for m, _ in pairs(pol.members) do
      members_list[#members_list + 1] = m
    end
    local mods_list = {}
    for m, _ in pairs(pol.moderators) do
      mods_list[#mods_list + 1] = m
    end
    output[addr] = {
      policy = pol.policy,
      members = members_list,
      moderators = mods_list,
    }
  end

  local parser = ucl.parser()
  -- Use ucl to serialize (roundtrip through parser to get emitter)
  local json_str
  local ok, err = parser:parse_string("{}")
  if ok then
    local emitter = ucl.to_json(output, true)
    json_str = emitter
  end

  if not json_str then
    rspamd_logger.errx(rspamd_config, "%s: failed to serialize policies for cache", N)
    return
  end

  local tmp_path = settings.policy_file .. ".tmp"
  local f = io.open(tmp_path, "w")
  if not f then
    rspamd_logger.errx(rspamd_config, "%s: cannot write policy cache to %s", N, tmp_path)
    return
  end
  f:write(json_str)
  f:close()
  os.rename(tmp_path, settings.policy_file)
  rspamd_logger.infox(rspamd_config, "%s: saved policy cache to %s", N, settings.policy_file)
end

-- Fetch aliases from Mailcow API and update the in-memory policy table.
-- Called periodically via add_periodic and also on initial load.
local function sync_policies(cfg, ev_base)
  if not settings.api_key or not settings.hostname then
    rspamd_logger.errx(cfg, "%s: api_key or hostname not configured, skipping sync", N)
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
        rspamd_logger.errx(cfg, "%s: API request failed: %s", N, err_message)
        return
      end

      if code ~= 200 then
        rspamd_logger.errx(cfg, "%s: API returned HTTP %s", N, code)
        return
      end

      if not body or #body == 0 then
        rspamd_logger.errx(cfg, "%s: API returned empty body", N)
        return
      end

      -- Parse JSON response
      local parser = ucl.parser()
      local ok, parse_err = parser:parse_string(tostring(body))
      if not ok then
        rspamd_logger.errx(cfg, "%s: failed to parse API response: %s", N, parse_err)
        return
      end

      local aliases = parser:get_object()
      local new_policies, result = parse_aliases(aliases)

      if not new_policies then
        rspamd_logger.errx(cfg, "%s: failed to process aliases: %s", N, result)
        return
      end

      policies = new_policies
      rspamd_logger.infox(cfg, "%s: synced %s policies from API", N, result)

      -- Save to disk cache for cold starts
      save_policy_file(new_policies)
    end,
  })
end

-- Read module configuration from rspamd config block
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

-- Validate required configuration
if not settings.api_key or not settings.hostname then
  rspamd_logger.errx(rspamd_config,
    "%s: missing required config (api_key and hostname must be set in alias_policy {} block)", N)
end

-- Load cached policies from disk for immediate availability on cold start
load_policy_file()

-- Register periodic sync via rspamd's event loop
rspamd_config:add_on_load(function(cfg, ev_base, _worker)
  -- Run first sync immediately on worker start
  sync_policies(cfg, ev_base)

  -- Schedule periodic syncs
  rspamd_config:add_periodic(ev_base, settings.sync_interval, function(periodic_cfg, periodic_ev_base)
    sync_policies(periodic_cfg, periodic_ev_base)
    return true  -- keep the periodic timer running
  end)
end)

-- Rejects the email with an SMTP 5xx response and logs the reason.
local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "%s: REJECT %s -> %s (%s)", N, sender, list_addr, msg)
  task:insert_result("ALIAS_POLICY", 1.0, list_addr)
  task:set_pre_result("reject", msg, N)
  return true
end

-- Main prefilter callback. For each recipient, looks up the alias policy
-- and enforces it. If any recipient fails the check, the message is rejected.
-- Policy types:
--   public - anyone can send
--   domain - sender must be in the same domain as the alias
--   membersonly - sender must be a goto destination of the alias
--   moderatorsonly - sender must be in the moderators list
--   membersandmoderatorsonly - sender must be a member or moderator
local function check_policy(task)
  -- Guard: if the policies table is empty, allow the message (fail-open)
  if not next(policies) then
    return
  end

  -- Extract sender and recipients from the SMTP transaction
  local sender = task:get_from("smtp")
  local rcpts = task:get_recipients("smtp")
  if not sender or not rcpts then
    return
  end
  sender = sender[1].addr:lower()
  local sender_domain = sender:match("@(.+)")

  -- Check each recipient against its alias policy
  for _, rcpt in ipairs(rcpts) do
    local list_addr = rcpt.addr:lower()
    local list = policies[list_addr]
    if list then
      local policy = list.policy
      rspamd_logger.infox(task, "%s: checking %s -> %s (policy=%s)", N, sender, list_addr, policy)

      if policy == "public" then
        -- No restrictions: anyone can send
        rspamd_logger.infox(task, "%s: ALLOW %s -> %s (public)", N, sender, list_addr)
        break
      elseif policy == "domain" then
        -- Sender must match the alias domain
        local list_domain = list_addr:match("@(.+)")
        if sender_domain ~= list_domain then
          reject(task, sender, list_addr, "Sender not in same domain")
          return
        else
          rspamd_logger.infox(task, "%s: ALLOW %s -> %s (domain match)", N, sender, list_addr)
        end
      elseif policy == "membersonly" then
        -- Sender must be a goto destination (member) of the alias
        if not list.members[sender] then
          reject(task, sender, list_addr, "Sender not a member")
          return
        else
          rspamd_logger.infox(task, "%s: ALLOW %s -> %s (member)", N, sender, list_addr)
        end
      elseif policy == "moderatorsonly" then
        -- Sender must be in the moderators list defined in private_comment
        if not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a moderator")
          return
        else
          rspamd_logger.infox(task, "%s: ALLOW %s -> %s (moderator)", N, sender, list_addr)
        end
      elseif policy == "membersandmoderatorsonly" then
        -- Sender must be either a member or a moderator
        if not list.members[sender] and not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a member or moderator")
          return
        else
          rspamd_logger.infox(task, "%s: ALLOW %s -> %s (member/moderator)", N, sender, list_addr)
        end
      else
        -- Unknown policy value: default to allowing (fail-open)
        rspamd_logger.warnx(task, "%s: unknown policy '%s' for %s, defaulting to allow", N, policy, list_addr)
        rspamd_logger.infox(task, "%s: ALLOW %s -> %s (unknown policy)", N, sender, list_addr)
      end
    end
  end
end

rspamd_config:register_symbol({
  name = "ALIAS_POLICY",
  type = "prefilter",
  priority = 10, -- High priority to run before Mailcow whitelists
  callback = check_policy,
})
