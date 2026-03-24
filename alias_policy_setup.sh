#!/bin/bash
set -e

# Copy the alias list sync script and make it executable
cp /hooks/alias_list_sync.sh /usr/local/bin/alias_list_sync.sh
chmod +x /usr/local/bin/alias_list_sync.sh

mkdir -p /etc/cron.d
# Create a cron entry to run the alias list sync script every 5 minutes
cat <<EOF >/etc/cron.d/alias_list_sync
*/5 * * * * source /etc/alias_list_sync.env && /usr/local/bin/alias_list_sync.sh
EOF

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/list_policies.json ]; then
  echo '{}' >/etc/rspamd/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
mkdir -p /etc/rspamd/plugins.d
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Add a configuration block so rspamd does not auto-disable the module
if ! grep -q 'alias_policy' /etc/rspamd/rspamd.conf.local 2>/dev/null; then
  cat <<EOF >>/etc/rspamd/rspamd.conf.local
alias_policy {
}
EOF
fi

# Create an env file for the sync script
cat <<EOF >/etc/alias_list_sync.env
MAILCOW_API_KEY=${API_KEY_READ_ONLY}
MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
EOF
