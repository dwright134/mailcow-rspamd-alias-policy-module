#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Remove any existing alias_policy block (may be stale or from an older version)
# and append a fresh one while preserving all other local config.
touch /etc/rspamd/rspamd.conf.local
sed -i '/^alias_policy[[:space:]]*{/,/^}/d' /etc/rspamd/rspamd.conf.local

cat <<EOF >>/etc/rspamd/rspamd.conf.local
alias_policy {
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 60;
}
EOF
