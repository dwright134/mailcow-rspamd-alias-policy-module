# Mailcow Rspamd Alias Policy Module

A lightweight mailing list policy enforcement system for [Mailcow](https://mailcow.email/). Created to fill a gap when migrating from [iRedMail](https://www.iredmail.org/), which provides alias ACLs through its `policyserver` -- a feature missing in Mailcow. It uses Mailcow's alias `private_comment` field to define sending policies, and enforces them via an [Rspamd](https://rspamd.com/) Lua prefilter.

## How It Works

The module is a single Rspamd Lua plugin (`alias_policy.lua`) with two cooperating parts:

1. **API sync** (primary controller only) -- The primary controller worker fetches aliases from the Mailcow API using rspamd's built-in HTTP client (`rspamd_http`) on a periodic timer (`add_periodic`). Before writing, it computes a hash of the new policy data and compares it against the cached hash. The policy file is only updated if the data has changed. On startup, if cached policies exist from a previous run, the initial sync is skipped.

2. **Policy enforcement** (all workers) -- All workers monitor the policy file via rspamd's map subsystem (`add_map`), which uses inotify/ev_stat to detect changes and pushes updated content to workers automatically. Each incoming message is checked against the in-memory policy table as a high-priority prefilter.

```
Mailcow API (/api/v1/get/alias/all)
       |
       v  (rspamd_http, primary controller only, every 5 min)
       |
       |  (hash comparison - skip if unchanged)
       v
/etc/rspamd/list_policies.json  (atomic write, only if changed)
       |
       v  (map subsystem, inotify, all workers)
in-memory policy table + cached hash
       |
       v  (prefilter, priority 10)
ALLOW or REJECT (SMTP 5xx)
```

No external scripts, background processes, or extra dependencies required. On first run, policies are fetched from the API. On subsequent runs, cached policies are used immediately and the API is only hit if policies have actually changed.

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

2. Copy the module files into mailcow:

   Copy the contents of this repo to `mailcow-dockerized/data/hooks/rspamd/`.

3. Restart mailcow:

   ```bash
   docker compose restart
   ```

   This applies the environment variables and triggers the setup script (`alias_policy_setup.sh`) which will:
   - Install `alias_policy.lua` into Rspamd's plugins directory
   - Register the module in `rspamd.conf.local` with API credentials
   - Initialize the policy cache file

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MAILCOW_HOSTNAME` | Yes | Hostname of the Mailcow instance (already set in `mailcow.conf`) |
| `API_KEY_READ_ONLY` | Yes | Read-only API key, set in `mailcow.conf` |

## Module Configuration

The setup script writes the following configuration block to `rspamd.conf.local`:

```
alias_policy {
  api_key = "<your-api-key>";
  hostname = "<your-hostname>";
  sync_interval = 300;
}
```

| Option | Default | Description |
|---|---|---|
| `api_key` | *(required)* | Mailcow read-only API key |
| `hostname` | *(required)* | Mailcow hostname for API requests |
| `sync_interval` | `300` | Seconds between API syncs |
| `policy_file` | `/etc/rspamd/list_policies.json` | Path to the disk cache file |

## File Locations

| File | Path | Description |
|---|---|---|
| Lua module | `/etc/rspamd/plugins.d/alias_policy.lua` | Rspamd prefilter that syncs and enforces policies |
| Policy cache | `/etc/rspamd/list_policies.json` | Cached policy data for cold starts (auto-managed) |

## Logging

The module logs all activity prefixed with `alias_policy:` for easy filtering. Each message includes the sender, recipient, policy, and decision.

| Event | Log Level | Example |
|---|---|---|
| Policies synced | `info` | `alias_policy: synced 12 policies from API` |
| Cache loaded | `info` | `alias_policy: loaded 12 policies from cache file` |
| Using cached policies | `info` | `alias_policy: using cached policies, skipping initial sync` |
| Policy unchanged | `info` | `alias_policy: policy unchanged, skipping write` |
| ACL check | `info` | `alias_policy: checking user@example.com -> list@domain.com (policy=membersonly)` |
| Allowed | `info` | `alias_policy: ALLOW user@example.com -> list@domain.com (member)` |
| Rejected | `info` | `alias_policy: REJECT user@example.com -> list@domain.com (Sender not a member)` |
| API failure | `error` | `alias_policy: API request failed: connection refused` |
| Parse error | `error` | `alias_policy: failed to parse API response: ...` |

View logs in the Rspamd container:
```bash
docker compose logs rspamd-mailcow | grep 'alias_policy:'
```
