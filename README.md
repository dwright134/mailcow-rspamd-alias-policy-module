# Mailcow Rspamd Alias Policy Module

A lightweight mailing list policy enforcement system for [Mailcow](https://mailcow.email/). It uses Mailcow's alias `private_comment` field to define sending policies, and enforces them via an [Rspamd](https://rspamd.com/) Lua prefilter.

## How It Works

The system has two components:

1. **Sync script** (`alias_list_sync.sh`) -- A cron job that runs every 5 minutes. It fetches all active aliases from the Mailcow API, parses the `private_comment` field for policy configuration, and writes a JSON file (`/etc/rspamd/list_policies.json`).

2. **Rspamd Lua module** (`alias_policy.lua`) -- A prefilter that loads the JSON file (reloading every 60 seconds) and checks incoming messages against the configured policies. Unauthorized senders receive an SMTP reject.

```
Mailcow API  -->  alias_list_sync.sh (cron)  -->  list_policies.json  -->  alias_policy.lua (rspamd)
```

Changes to alias policies in Mailcow can take up to ~6 minutes to take effect (5-minute cron interval + 60-second Lua reload interval).

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

1. Set the required environment variables:
   - `MAILCOW_HOSTNAME` -- Your Mailcow hostname (e.g., `mail.example.com`)
   - `MAILCOW_API_KEY` -- A Mailcow API key with read access to aliases

2. Run the setup script:
   ```bash
   ./alias_policy_setup.sh
   ```

   This will:
   - Copy `alias_list_sync.sh` to `/usr/local/bin/`
   - Create a cron job to run the sync every 5 minutes
   - Install `alias_policy.lua` into Rspamd's configuration directory
   - Create an env file at `/etc/alias_list_sync.env`

3. Restart Rspamd to load the Lua module.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MAILCOW_HOSTNAME` | Yes | Hostname of the Mailcow instance (used for API requests) |
| `MAILCOW_API_KEY` | Yes | API key for authenticating with the Mailcow API |

## File Locations

| File | Path | Description |
|---|---|---|
| Sync script | `/usr/local/bin/alias_list_sync.sh` | Cron job that fetches aliases and writes JSON |
| Lua module | `/etc/rspamd/local.d/alias_policy.lua` | Rspamd prefilter that enforces policies |
| Policy JSON | `/etc/rspamd/list_policies.json` | Generated policy data (do not edit manually) |
| Env file | `/etc/alias_list_sync.env` | Environment variables for the sync script |
