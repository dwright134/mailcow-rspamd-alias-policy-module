-- alias_policy.lua
-- Rspamd prefilter module that enforces mailing list sending policies
-- for Mailcow aliases. Policies are defined in the alias's private_comment
-- field and synced via alias_list_sync.sh to list_policies.json.
--
-- Policy data is loaded via rspamd's map subsystem (callback map), which
-- monitors the file for changes using inotify/ev_stat in the master process
-- and distributes updated data to workers without blocking them.

-- Rspamd modules
local rspamd_logger = require("rspamd_logger")
local ucl = require("ucl")

-- Configuration
local policy_file = "/etc/rspamd/list_policies.json"  -- JSON file written by sync daemon
local policies = {}  -- In-memory policy table (address -> policy data)

-- Converts an array of strings into a lookup set (lowercase keys).
-- Used to quickly check if a sender is in the members or moderators list.
local function list_to_set(list)
  local set = {}
  if list then
    for _, v in ipairs(list) do
      set[v:lower()] = true
    end
  end
  return set
end

-- Map callback: called by rspamd's map subsystem whenever the policy file
-- changes. Receives the raw file content as a string, parses it with UCL,
-- and rebuilds the in-memory policies table. This runs in the worker context
-- but is triggered by the master process's file monitoring, so workers never
-- do their own file I/O or polling.
local function on_policy_map_load(data)
  if not data or #data == 0 then
    rspamd_logger.warnx(rspamd_config, "alias_policy: map callback received empty data")
    return
  end

  local parser = ucl.parser()
  local ok, err = parser:parse_string(data)
  if not ok then
    rspamd_logger.errx(rspamd_config, "alias_policy: failed to parse policy data: %s", err)
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
  rspamd_logger.infox(rspamd_config, "alias_policy: loaded %s policies from map", count)
end

-- Register the policy file as a callback map. The map subsystem handles:
--   - File monitoring (inotify where available, ev_stat fallback)
--   - Automatic reload on file change
--   - Delivering the full file content to on_policy_map_load
local policy_map = rspamd_config:add_map({
  type = "callback",
  url = "file://" .. policy_file,
  description = "Alias sending policy map (JSON)",
  callback = on_policy_map_load,
})

if not policy_map then
  rspamd_logger.errx(rspamd_config, "alias_policy: failed to add policy map for %s", policy_file)
end

-- Rejects the email with an SMTP 5xx response and logs the reason.
local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "alias_policy: REJECT %s -> %s (%s)", sender, list_addr, msg)
  task:insert_result("ALIAS_POLICY", 1.0, list_addr)
  task:set_pre_result("reject", msg)
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
  -- Guard: if the map has not loaded yet, allow the message (fail-open)
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
      rspamd_logger.infox(task, "alias_policy: checking %s -> %s (policy=%s)", sender, list_addr, policy)

      if policy == "public" then
        -- No restrictions: anyone can send
        rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (public)", sender, list_addr)
        break
      elseif policy == "domain" then
        -- Sender must match the alias domain
        local list_domain = list_addr:match("@(.+)")
        if sender_domain ~= list_domain then
          reject(task, sender, list_addr, "Sender not in same domain")
          return
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (domain match)", sender, list_addr)
        end
      elseif policy == "membersonly" then
        -- Sender must be a goto destination (member) of the alias
        if not list.members[sender] then
          reject(task, sender, list_addr, "Sender not a member")
          return
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (member)", sender, list_addr)
        end
      elseif policy == "moderatorsonly" then
        -- Sender must be in the moderators list defined in private_comment
        if not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a moderator")
          return
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (moderator)", sender, list_addr)
        end
      elseif policy == "membersandmoderatorsonly" then
        -- Sender must be either a member or a moderator
        if not list.members[sender] and not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a member or moderator")
          return
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (member/moderator)", sender, list_addr)
        end
      else
        -- Unknown policy value: default to allowing (fail-open)
        rspamd_logger.warnx(task, "alias_policy: unknown policy '%s' for %s, defaulting to allow", policy, list_addr)
        rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (unknown policy)", sender, list_addr)
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
