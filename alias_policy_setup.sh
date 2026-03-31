#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Write a dedicated module config file instead of editing rspamd.conf.local.
# This avoids in-place rewrite failures on mounted/busy config files.
cat <<EOF >/etc/rspamd/local.d/alias_policy.conf
alias_policy {
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 60;
}
EOF
