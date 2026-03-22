#!/bin/bash

# Copy the list sync script and make it executable
cp /hooks/rspamd/mailcow_list_sync.py /usr/local/bin/mailcow_list_sync.py
chmod +x /usr/local/bin/mailcow_list_sync.py

# Create a cron entry to run the list sync script every 5 minutes
cat <<EOF >/etc/cron.d/mailcow_list_sync
*/5 * * * * source /etc/mailcow_list_sync.env && /usr/bin/python3 /usr/local/bin/mailcow_list_sync.py
EOF

# Copy the mail list policy moduel for rpamd
cp /hooks/rspamd/list_policy.lua /etc/rpamd/local.d/list_policy.lua

cat <<EOF >/etc/mailcow_list_sync.env
MAILCOW_DBHOST= mysql
MAILCOW_DBNAME: ${DBNAME}
MAILCOW_DBUSER: ${DBUSER}
MAILCOW_DBPASS: ${DBPASS}
EOF
