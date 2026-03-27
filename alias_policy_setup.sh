#!/bin/bash
set -e

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/list_policies.json ]; then
  echo '{}' >/etc/rspamd/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
mkdir -p /etc/rspamd/plugins.d
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Add configuration block with API credentials so the Lua module can
# fetch aliases directly from the Mailcow API (no external scripts needed)
if ! grep -q 'alias_policy' /etc/rspamd/rspamd.conf.local >/dev/null 2>&1; then
  cat <<EOF >>/etc/rspamd/rspamd.conf.local
alias_policy {
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 300;
}
EOF
fi
