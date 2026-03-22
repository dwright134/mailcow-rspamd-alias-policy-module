local rspamd_logger = require("rspamd_logger")
local ucl = require("ucl")

local policy_file = "/etc/rspamd/list_policies.json"
local policies = {}

local function list_to_set(list)
  local set = {}
  if list then
    for _, v in ipairs(list) do
      set[v] = true
    end
  end
  return set
end

local function load_policies()
  local f = io.open(policy_file, "r")
  if not f then
    return
  end
  local data = f:read("*all")
  f:close()
  local raw = ucl.parser():parse_string(data)
  policies = {}
  for list_addr, val in pairs(raw) do
    policies[list_addr] = {
      policy = val.policy,
      members = list_to_set(val.members),
      moderators = list_to_set(val.moderators),
    }
  end
end

load_policies()
rspamd_config:add_periodic(60.0, load_policies)

local function reject(task, sender, list_addr, msg)
  rspamd_logger.infox(task, "Sender rejected: %s -> %s", sender, list_addr)
  task:set_pre_result("reject", msg)
end

local function check_policy(task)
  local sender = task:get_from("smtp")
  local rcpts = task:get_recipients("smtp")
  if not sender or not rcpts then
    return
  end
  sender = sender[1].addr
  local sender_domain = sender:match("@(.+)")

  for _, rcpt in ipairs(rcpts) do
    local list_addr = rcpt.addr
    local list = policies[list_addr]
    if not list then
      return
    end

    local policy = list.policy

    if policy == "public" then
      return
    end

    if policy == "domain" then
      local list_domain = list_addr:match("@(.+)")
      if sender_domain ~= list_domain then
        reject(task, sender, list_addr, "Sender not in same domain")
      end
      return
    end

    if policy == "membersonly" and not list.members[sender] then
      reject(task, sender, list_addr, "Sender not a member")
    end

    if policy == "moderatorsonly" and not list.moderators[sender] then
      reject(task, sender, list_addr, "Sender not a moderator")
    end
  end
end

rspamd_config:register_symbol({
  name = "ALIAS_POLICY",
  type = "prefilter",
  callback = check_policy,
})
