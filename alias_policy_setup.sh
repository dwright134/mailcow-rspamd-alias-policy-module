#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Configure the module using its per-module local.d file. For files in
# local.d/<module>.conf, Rspamd expects bare options without wrapping them
# in an alias_policy { ... } block.
cat <<EOF >/etc/rspamd/local.d/alias_policy.conf
enabled = true;
api_key = "${API_KEY_READ_ONLY}";
hostname = "${MAILCOW_HOSTNAME}";
sync_interval = 60;
EOF
