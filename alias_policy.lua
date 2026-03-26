-- alias_policy.lua
-- Rspamd prefilter module that enforces mailing list sending policies
-- for Mailcow aliases. Policies are defined in the alias's private_comment
-- field and synced via alias_list_sync.sh to list_policies.json.

-- Rspamd modules
local rspamd_logger = require("rspamd_logger")
local rspamd_util = require("rspamd_util")

-- Configuration
local policy_file = "/etc/rspamd/list_policies.json"  -- JSON file written by sync script
local sync_script = "/usr/local/bin/alias_list_sync.sh"  -- Fetches policies from Mailcow API
local policies = {}  -- In-memory policy table (address -> policy data)
local last_sync = 0  -- Timestamp of last sync (rate-limited to 60s)

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

-- Runs the sync script to fetch latest policies from Mailcow API.
-- Rate-limited to once every 60 seconds to avoid excessive API calls.
local function sync_policies()
  local now = os.time()
  if now - last_sync < 60 then
    return
  end
  last_sync = now
  local rc = os.execute(sync_script .. " >/dev/null 2>&1")
  if rc ~= 0 then
    rspamd_logger.errx("alias_policy: sync script failed (exit code %s)", rc)
  end
end

-- Reads the policy JSON file and populates the in-memory policies table.
-- Each entry maps an alias address to its policy, members, and moderators.
local function load_policies()
  local f = io.open(policy_file, "r")
  if not f then
    rspamd_logger.warnx("alias_policy: cannot open policy file: %s", policy_file)
    return
  end
  local data = f:read("*all")
  f:close()

  local raw, err = rspamd_util.json_decode(data)
  if not raw then
    rspamd_logger.errx("alias_policy: failed to parse %s: %s", policy_file, err)
    return
  end

  local count = 0
  policies = {}
  for list_addr, val in pairs(raw) do
    policies[list_addr:lower()] = {
      policy = val.policy,
      members = list_to_set(val.members),
      moderators = list_to_set(val.moderators),
    }
    count = count + 1
  end
  rspamd_logger.infox("alias_policy: loaded %s policies from %s", count, policy_file)
end

-- Load policies on module initialization
sync_policies()
load_policies()

-- Rejects the email with an SMTP 5xx response and logs the reason.
local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "alias_policy: REJECT %s -> %s (%s)", sender, list_addr, msg)
  task:set_pre_result("reject", msg)
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
  -- Refresh policies from Mailcow (rate-limited)
  sync_policies()
  load_policies()

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

-- Register as a prefilter (runs before all other Rspamd filters)
rspamd_config.ALIAS_POLICY = {
  type = "prefilter",
  callback = check_policy,
}
