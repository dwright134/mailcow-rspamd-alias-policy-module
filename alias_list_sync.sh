#!/usr/bin/env bash
# Generate Rspamd JSON policy from Mailcow API (env-configured)
set -euo pipefail

# Load env file if exists
[[ -f "/etc/alias_list_sync.env" ]] && source /etc/alias_list_sync.env

# Ensure required env vars are set
: "${MAILCOW_HOSTNAME:?MAILCOW_HOSTNAME must be set}"
: "${MAILCOW_API_KEY:?MAILCOW_API_KEY must be set}"

RSPAMD_POLICY_FILE="/etc/rspamd/list_policies.json"
TMP_OUTPUT="${RSPAMD_POLICY_FILE}.tmp"

# Allowed policy values
VALID_POLICIES=("public" "domain" "membersonly" "moderatorsonly" "membersandmoderatorsonly")

# Fetch aliases from Mailcow API
response=$(curl -sS -H "accept: application/json" -H "X-API-Key: $MAILCOW_API_KEY" "https://$MAILCOW_HOSTNAME/api/v1/get/alias/all") || {
  echo "$(date "+%Y-%m-%d %H:%M:%S") #2(alias-policy-sync) <pid:\$\$>; log; Error: Mailcow API request failed"
  exit 1
}
# Validate response
if ! echo "$response" | jq empty 2>/dev/null && [[ ! "$response" =~ ^\[ ]]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") #2(alias-policy-sync) <pid:\$\$>; log; Error: API did not return a valid JSON array"
  exit 1
fi

# Valid policies list as a jq-friendly string
valid_policies='["public","domain","membersonly","moderatorsonly","membersandmoderatorsonly"]'

# Build the output JSON using jq
json=$(echo "$response" | jq --argjson valid "$valid_policies" '
  [.[] | select(.active == 1)] |
  map(
    {
      key: (.address | ascii_downcase),
      value: (
        (.private_comment // "" | ascii_downcase) as $raw |
        ($raw | split("::")) as $parts |
        ($parts[0] // "") as $p |
        {
          policy: (
            if ($valid | index($p)) then $p else "public" end
          ),
          members: (
            (.goto // "") |
            if . == "" then []
            else split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | map(select(. != ""))
            end
          ),
          moderators: (
            if ($parts | length) > 1 then
              ($parts[1] // "") |
              if . == "" then []
              else split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | map(select(. != ""))
              end
            else []
            end
          )
        }
      )
    }
  ) | from_entries
')

# Only update file if different
if [[ -f "$RSPAMD_POLICY_FILE" ]] && cmp -s <(echo "$json") "$RSPAMD_POLICY_FILE"; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") #2(alias-policy-sync) <pid:\$\$>; log; No policy changes detected. Not updating $RSPAMD_POLICY_FILE."
  exit 0
fi

# Atomic write
echo "$json" >"$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$RSPAMD_POLICY_FILE"
echo "$(date "+%Y-%m-%d %H:%M:%S") #2(alias-policy-sync) <pid:\$\$>; log; Policy changes detected. Updating $RSPAMD_POLICY_FILE."
