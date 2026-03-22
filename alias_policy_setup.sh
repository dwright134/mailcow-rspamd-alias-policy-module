#!/bin/bash

# Copy the alias list sync script and make it executable
cp /hooks/rspamd/alias_list_sync.sh /usr/local/bin/alias_list_sync.sh
chmod +x /usr/local/bin/alias_list_sync.sh

# Create a cron entry to run the alias list sync script every 5 minutes
cat <<EOF >/etc/cron.d/alias_list_sync
*/5 * * * * source /etc/alias_list_sync.env && /usr/local/bin/alias_list_sync.sh
EOF

# Copy the alias list policy module for rpamd
cp /hooks/rspamd/alias_policy.lua /etc/rpamd/local.d/alias_policy.lua

# Create and env file for connecting to the DB
cat <<EOF >/etc/alias_list_sync.env
MAILCOW_API_KEY= ${API_KEY}
MAILCOW_HOSTNAME: ${MAILCOW_HOSTNAME}
EOF
