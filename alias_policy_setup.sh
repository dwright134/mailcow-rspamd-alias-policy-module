#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Refresh the alias_policy block in rspamd.conf.local without using sed -i,
# which can fail on mounted or busy config files.
touch /etc/rspamd/rspamd.conf.local
tmp_path="$(mktemp)"
trap 'rm -f "$tmp_path"' EXIT
sed '/^[[:space:]]*alias_policy[[:space:]]*{/,/^[[:space:]]*}/d' /etc/rspamd/rspamd.conf.local >"$tmp_path"

cat <<EOF >>"$tmp_path"
alias_policy {
  api_key = "${API_KEY_READ_ONLY}";
  hostname = "${MAILCOW_HOSTNAME}";
  sync_interval = 60;
}
EOF

cat "$tmp_path" >/etc/rspamd/rspamd.conf.local
rm -f /etc/rspamd/local.d/alias_policy.conf
trap - EXIT
rm -f "$tmp_path"
