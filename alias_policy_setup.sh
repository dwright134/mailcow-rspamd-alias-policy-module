#!/bin/bash
set -e

mkdir -p /etc/rspamd/local.d /etc/rspamd/plugins.d

sync_interval="${ALIAS_POLICY_SYNC_INTERVAL:-300}"
if ! [[ "$sync_interval" =~ ^[0-9]+$ ]] || [ "$sync_interval" -le 0 ]; then
  echo "alias_policy: invalid ALIAS_POLICY_SYNC_INTERVAL='${ALIAS_POLICY_SYNC_INTERVAL}'; expected a positive integer, defaulting to 300" >&2
  sync_interval="300"
fi

# Initialize the policy file as empty JSON if it doesn't exist yet
if [ ! -f /etc/rspamd/local.d/list_policies.json ]; then
  echo '{}' >/etc/rspamd/local.d/list_policies.json
fi

# Install the alias policy module into rspamd's plugins directory
cp /hooks/alias_policy.lua /etc/rspamd/plugins.d/alias_policy.lua

# Refresh the alias_policy block in rspamd.conf.local.
touch /etc/rspamd/rspamd.conf.local
tmp_local=$(mktemp)
trap 'rm -f "$tmp_local"' EXIT
sed '/^[[:space:]]*alias_policy[[:space:]]*{/,/^[[:space:]]*}/d' /etc/rspamd/rspamd.conf.local >"$tmp_local"
cat "$tmp_local" >/etc/rspamd/rspamd.conf.local
rm -f "$tmp_local"
trap - EXIT

cat <<'EOF' >>/etc/rspamd/rspamd.conf.local
alias_policy {
  .include(try=true;priority=1,duplicate=merge) "$LOCAL_CONFDIR/local.d/alias_policy.conf"
}
EOF

cat <<EOF >/etc/rspamd/local.d/alias_policy.conf
enabled = true;
api_key = "${API_KEY_READ_ONLY}";
hostname = "${MAILCOW_HOSTNAME}";
sync_interval = ${sync_interval};
EOF
