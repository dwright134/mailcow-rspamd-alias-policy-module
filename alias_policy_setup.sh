#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Refresh the alias_policy block in rspamd.conf.override.
touch /etc/rspamd/rspamd.conf.override
sed -i '/^[[:space:]]*alias_policy[[:space:]]*{/,/^[[:space:]]*}/d' /etc/rspamd/rspamd.conf.override

cat <<EOF >>/etc/rspamd/rspamd.conf.override
alias_policy {
  enabled = true;
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 60;
}
EOF
