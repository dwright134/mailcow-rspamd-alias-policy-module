local rspamd_logger = require("rspamd_logger")
local ucl = require("ucl")

local policy_file = "/etc/rspamd/list_policies.json"
local sync_script = "/usr/local/bin/alias_list_sync.sh"
local policies = {}
local last_sync = 0

local function list_to_set(list)
  local set = {}
  if list then
    for _, v in ipairs(list) do
      set[v:lower()] = true
    end
  end
  return set
end

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

local function load_policies()
  local f = io.open(policy_file, "r")
  if not f then
    rspamd_logger.warnx("alias_policy: cannot open policy file: %s", policy_file)
    return
  end
  local data = f:read("*all")
  f:close()

  local parser = ucl.parser()
  local ok, err = parser:parse_string(data)
  if not ok then
    rspamd_logger.errx("alias_policy: failed to parse %s: %s", policy_file, err)
    return
  end
  local raw = parser:get_object()

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

sync_policies()
load_policies()

local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "alias_policy: REJECT %s -> %s (%s)", sender, list_addr, msg)
  task:set_pre_result("reject", msg)
end

local function check_policy(task)
  sync_policies()
  load_policies()

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
      rspamd_logger.infox(task, "alias_policy: checking %s -> %s (policy=%s)", sender, list_addr, policy)

      if policy == "public" then
        rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (public)", sender, list_addr)
      elseif policy == "domain" then
        local list_domain = list_addr:match("@(.+)")
        if sender_domain ~= list_domain then
          reject(task, sender, list_addr, "Sender not in same domain")
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (domain match)", sender, list_addr)
        end
      elseif policy == "membersonly" then
        if not list.members[sender] then
          reject(task, sender, list_addr, "Sender not a member")
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (member)", sender, list_addr)
        end
      elseif policy == "moderatorsonly" then
        if not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a moderator")
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (moderator)", sender, list_addr)
        end
      elseif policy == "membersandmoderatorsonly" then
        if not list.members[sender] and not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a member or moderator")
        else
          rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (member/moderator)", sender, list_addr)
        end
      else
        rspamd_logger.warnx(task, "alias_policy: unknown policy '%s' for %s, defaulting to allow", policy, list_addr)
        rspamd_logger.infox(task, "alias_policy: ALLOW %s -> %s (unknown policy)", sender, list_addr)
      end
    end
  end
end

rspamd_config.ALIAS_POLICY = {
  type = "prefilter",
  callback = check_policy,
}
