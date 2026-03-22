local rspamd_logger = require("rspamd_logger")
local ucl = require("ucl")

local policy_file = "/etc/rspamd/list_policies.json"
local policies = {}

local function list_to_set(list)
  local set = {}
  if list then
    for _, v in ipairs(list) do
      set[v:lower()] = true
    end
  end
  return set
end

local function load_policies()
  local f = io.open(policy_file, "r")
  if not f then
    rspamd_logger.warnx(rspamd_config, "Cannot open policy file: %s", policy_file)
    return
  end
  local data = f:read("*all")
  f:close()

  local parser = ucl.parser()
  local ok, err = parser:parse_string(data)
  if not ok then
    rspamd_logger.errx(rspamd_config, "Failed to parse %s: %s", policy_file, err)
    return
  end
  local raw = parser:get_object()

  policies = {}
  for list_addr, val in pairs(raw) do
    policies[list_addr:lower()] = {
      policy = val.policy,
      members = list_to_set(val.members),
      moderators = list_to_set(val.moderators),
    }
  end
end

load_policies()
rspamd_config:add_periodic(60.0, load_policies)

local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "Sender rejected: %s -> %s (%s)", sender, list_addr, msg)
  task:set_pre_result("reject", msg)
end

local function check_policy(task)
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

      if policy == "public" then
        -- allow anyone, no action needed
      elseif policy == "domain" then
        local list_domain = list_addr:match("@(.+)")
        if sender_domain ~= list_domain then
          reject(task, sender, list_addr, "Sender not in same domain")
        end
      elseif policy == "members" then
        if not list.members[sender] then
          reject(task, sender, list_addr, "Sender not a member")
        end
      elseif policy == "moderators" then
        if not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a moderator")
        end
      elseif policy == "membersandmoderators" then
        if not list.members[sender] and not list.moderators[sender] then
          reject(task, sender, list_addr, "Sender not a member or moderator")
        end
      else
        rspamd_logger.warnx(task, "Unknown policy '%s' for %s", policy, list_addr)
      end
    end
  end
end

rspamd_config:register_symbol({
  name = "ALIAS_POLICY",
  type = "prefilter",
  callback = check_policy,
})
