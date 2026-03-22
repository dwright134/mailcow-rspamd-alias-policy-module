#!/bin/bash

# Install python3
apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/lists/*

# Copy the alias list sync script and make it executable
cp /hooks/rspamd/alias_sync.py /usr/local/bin/alias_sync.py
chmod +x /usr/local/bin/alias_list_sync.py

# Create a cron entry to run the alias list sync script every 5 minutes
cat <<EOF >/etc/cron.d/alias_list_sync
*/5 * * * * source /etc/alias_list_sync.env && /usr/bin/python3 /usr/local/bin/alias_list_sync.py
EOF

# Copy the alias list policy module for rpamd
cp /hooks/rspamd/alias_list_policy.lua /etc/rpamd/local.d/alias_list_policy.lua

# Create and env file for connecting to the DB
cat <<EOF >/etc/alias_list_sync.env
MAILCOW_DBHOST= mysql
MAILCOW_DBNAME: ${DBNAME}
MAILCOW_DBUSER: ${DBUSER}
MAILCOW_DBPASS: ${DBPASS}
EOF
