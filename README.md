# Mailcow Rspamd Alias Policy Module

A lightweight mailing list policy enforcement system for [Mailcow](https://mailcow.email/). It uses Mailcow's alias `private_comment` field to define sending policies, and enforces them via an [Rspamd](https://rspamd.com/) Lua prefilter.

## How It Works

The system has two components:

1. **Sync script** (`alias_list_sync.sh`) -- Fetches all active aliases from the Mailcow API, parses the `private_comment` field for policy configuration, and writes a JSON file (`/etc/rspamd/list_policies.json`).

2. **Rspamd Lua module** (`alias_policy.lua`) -- A prefilter that calls the sync script, then loads the JSON file to check incoming messages against the configured policies. Unauthorized senders receive an SMTP reject. The sync script runs at most once every 60 seconds.

```
check_policy (incoming message)  -->  sync_policies (run alias_list_sync.sh)
                                   -->  load_policies (read list_policies.json)
                                   -->  enforce policy (ALLOW / REJECT)
```

Changes to alias policies in Mailcow take effect within ~60 seconds.

## Configuration

Policy configuration is done entirely through the **private_comment** field on each Mailcow alias. No other fields are used for policy metadata.

### Format

```
<policy>
```

or, for policies that require a moderator list:

```
<policy>::<moderator1@example.com>,<moderator2@example.com>
```

The `::` separator distinguishes the policy name from the optional comma-separated moderator email list.

### Available Policies

| Policy | `private_comment` value | Description |
|---|---|---|
| Public | `public` | Anyone can send to this alias. |
| Domain | `domain` | Only senders from the same domain as the alias can send. |
| Members Only | `membersonly` | Only the alias's destination addresses (goto targets) can send. |
| Moderators Only | `moderatorsonly::user1@example.com,user2@example.com` | Only the listed moderators can send. |
| Members and Moderators | `membersandmoderatorsonly::user1@example.com,user2@example.com` | Both destination addresses and listed moderators can send. |

If the `private_comment` field is empty or contains an unrecognized value, the policy defaults to `public`.

### Examples

**Allow anyone to send to a newsletter alias:**
```
private_comment: public
```

**Restrict an internal alias to same-domain senders:**
```
private_comment: domain
```

**Only allow alias members (goto targets) to send:**
```
private_comment: membersonly
```

**Only allow specific moderators to send:**
```
private_comment: moderatorsonly::admin@example.com,manager@example.com
```

**Allow both members and specific moderators:**
```
private_comment: membersandmoderatorsonly::admin@example.com,manager@example.com
```

**Members-only with optional moderators for future flexibility:**
```
private_comment: membersonly::backup-admin@example.com
```

The policy value and email addresses are case-insensitive. Whitespace around moderator emails is trimmed automatically.

### Members vs. Moderators

- **Members** are the alias's **goto destinations** -- the addresses that receive mail sent to the alias. These are managed through Mailcow's standard alias configuration, not through the `private_comment` field.
- **Moderators** are additional authorized senders defined in the `private_comment` field after the `::` separator. They do not need to be goto destinations.

## Prerequisites

- A running Mailcow instance with API access
- Rspamd (included with Mailcow)
- `jq` and `curl` available on the Rspamd container

## Installation

1. Set up the environment variables:

   - Add your read-only API key to `mailcow.conf` in your mailcow-dockerized directory:
     ```
     API_KEY_READ_ONLY=<your-read-only-api-key>
     ```
     (`MAILCOW_HOSTNAME` is already set in `mailcow.conf`.)

   - Create `docker-compose.override.yml` in your mailcow-dockerized directory to inject variables into the rspamd container:
     ```yaml
     services:
       rspamd-mailcow:
         environment:
           - MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
           - API_KEY_READ_ONLY=${API_KEY_READ_ONLY}
      ```

2. Run the setup script:

   The setup script (`alias_policy_setup.sh`) runs automatically when the rspamd container starts. After setting up the environment variables and applying the override, restart the container to trigger the setup:

   ```bash
   docker compose restart rspamd-mailcow
   ```

   The setup script will:
   - Copy `alias_list_sync.sh` to `/usr/local/bin/`
   - Create an env file at `/etc/alias_list_sync.env`
   - Install `alias_policy.lua` into Rspamd's plugins directory
   - Register the module in `rspamd.conf.local`

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MAILCOW_HOSTNAME` | Yes | Hostname of the Mailcow instance (already set in `mailcow.conf`) |
| `API_KEY_READ_ONLY` | Yes | Read-only API key, set in `mailcow.conf` |

## File Locations

| File | Path | Description |
|---|---|---|
| Sync script | `/usr/local/bin/alias_list_sync.sh` | Fetches aliases from Mailcow API and writes JSON |
| Lua module | `/etc/rspamd/plugins.d/alias_policy.lua` | Rspamd prefilter that enforces policies |
| Policy JSON | `/etc/rspamd/list_policies.json` | Generated policy data (do not edit manually) |
| Env file | `/etc/alias_list_sync.env` | Environment variables for the sync script |

## Logging

The module logs all activity prefixed with `alias_policy:` for easy filtering. Each message includes the sender, recipient, policy, and decision.

| Event | Log Level | Example |
|---|---|---|
| Policies loaded | `info` | `alias_policy: loaded 12 policies from /etc/rspamd/list_policies.json` |
| ACL check | `info` | `alias_policy: checking user@example.com -> list@domain.com (policy=membersonly)` |
| Allowed | `info` | `alias_policy: ALLOW user@example.com -> list@domain.com (member)` |
| Rejected | `info` | `alias_policy: REJECT user@example.com -> list@domain.com (Sender not a member)` |
| Sync failure | `error` | `alias_policy: sync script failed (exit code 1)` |
| File not found | `warn` | `alias_policy: cannot open policy file: /etc/rspamd/list_policies.json` |
| Parse error | `error` | `alias_policy: failed to parse ...: ...` |

View logs in the Rspamd container:
```bash
docker compose logs rspamd-mailcow | grep 'alias_policy:'
```
