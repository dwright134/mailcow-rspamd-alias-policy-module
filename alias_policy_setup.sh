#!/bin/bash
set -e

mkdir -p /etc/rspamd/custom /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Configure the custom Lua module using a top-level config file under
# /etc/rspamd/custom, which Mailcow mounts separately from rspamd.conf.local.
cat <<EOF >/etc/rspamd/custom/alias_policy.conf
alias_policy {
  enabled = true;
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 60;
}
EOF

rm -f /etc/rspamd/local.d/alias_policy.conf
