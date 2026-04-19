# Mailcow Rspamd Alias Policy Module

A lightweight mailing list policy enforcement system for [Mailcow](https://mailcow.email/). Created to fill a gap when migrating from [iRedMail](https://www.iredmail.org/), which provides alias ACLs through its `policyserver` -- a feature missing in Mailcow. It uses Mailcow's alias `private_comment` field to define sender policies, and enforces them via an [Rspamd](https://rspamd.com/) Lua prefilter.

## How It Works

This repo contains:

- `alias_policy.lua` - the Rspamd Lua prefilter that syncs and enforces alias policies
- `alias_policy_setup.sh` - the Mailcow hook script that installs the Lua module, refreshes the `alias_policy {}` wrapper block, and generates the module config on container start

At runtime, the Lua module has two cooperating parts:

1. **API sync** (primary controller only) -- The primary controller worker fetches aliases from the Mailcow API using rspamd's built-in HTTP client (`rspamd_http`) on a periodic timer (`add_periodic`). Before writing, it computes a hash of the new policy data and compares it against the cached hash. The policy file is only updated if the data has changed. On startup, if cached policies exist from a previous run, the initial sync is skipped.

2. **Policy enforcement** (all workers) -- All workers monitor the policy file via rspamd's map subsystem (`add_map`), which uses inotify/ev_stat to detect changes and pushes updated content to workers automatically. Each incoming message is checked against the in-memory policy table as a high-priority prefilter. For recipient matching, the module prefers the original recipient preserved by Mailcow/Postfix in RCPT ESMTP args (`ORCPT`) and falls back to SMTP and MIME recipients, so both direct-to-alias and Bcc-to-alias delivery paths are enforced.

```
Mailcow API (/api/v1/get/alias/all)
       |
       v  (rspamd_http, primary controller only, every sync interval)
       |
       |  (hash comparison - skip if unchanged)
       v
/etc/rspamd/local.d/list_policies.json  (atomic write, only if changed)
       |
       v  (map subsystem, inotify, all workers)
in-memory policy table + cached hash
       |
       v  (prefilter, priority 10)
ALLOW or REJECT (SMTP 5xx)
```

No extra daemons or external runtime dependencies are required. On first run, policies are fetched from the API. On subsequent runs, cached policies are used immediately and the API is only hit if policies have actually changed.

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
| Members Only | `membersonly` | Only the alias's destination addresses (goto targets) can send. |
| Moderators Only | `moderatorsonly::user1@example.com,user2@example.com` | Only the listed moderators can send. |
| Members and Moderators | `membersandmoderatorsonly::user1@example.com,user2@example.com` | Both destination addresses and listed moderators can send. |

Leave `private_comment` empty to keep an alias unrestricted. If the field is empty or contains an unrecognized or invalid value, no policy entry is written for that alias, so the module does not enforce a restriction for it.

If you want to limit an alias to same-domain senders, use the `Internal` checkbox when creating the alias in the Mailcow UI.

### Examples

**Allow anyone to send to a newsletter alias:**
```
private_comment:
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
      ALIAS_POLICY_SYNC_INTERVAL=300
      ```
      (`MAILCOW_HOSTNAME` is already set in `mailcow.conf`.)
      `ALIAS_POLICY_SYNC_INTERVAL` is optional unless you want to override the default.

   - Create `docker-compose.override.yml` in your mailcow-dockerized directory to inject variables into the rspamd container:
     ```yaml
      services:
         rspamd-mailcow:
           environment:
             - MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
             - API_KEY_READ_ONLY=${API_KEY_READ_ONLY}
             - ALIAS_POLICY_SYNC_INTERVAL=${ALIAS_POLICY_SYNC_INTERVAL:-300}
       ```

2. Copy the repo contents into mailcow:

   Copy the contents of this repo to `mailcow-dockerized/data/hooks/rspamd/`.

3. Restart the Rspamd container:

   ```bash
   docker compose restart rspamd-mailcow
   ```

   This applies the environment variables and triggers the setup hook (`alias_policy_setup.sh`), which will:
   - Install `alias_policy.lua` into Rspamd's plugins directory
   - Refresh the `alias_policy {}` wrapper block in `/etc/rspamd/rspamd.conf.local`
   - Write the module options to `/etc/rspamd/local.d/alias_policy.conf`
   - Create the policy cache file if it does not already exist

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MAILCOW_HOSTNAME` | Yes | Hostname of the Mailcow instance (already set in `mailcow.conf`) |
| `API_KEY_READ_ONLY` | Yes | Read-only API key, set in `mailcow.conf` |
| `ALIAS_POLICY_SYNC_INTERVAL` | No | Sync interval in seconds for alias policy refreshes; defaults to `300` |

## Module Configuration

The setup script writes an include wrapper to `/etc/rspamd/rspamd.conf.local`:

```
alias_policy {
  .include(try=true;priority=1,duplicate=merge) "$LOCAL_CONFDIR/local.d/alias_policy.conf"
}
```

It then writes the actual module options to `/etc/rspamd/local.d/alias_policy.conf`, using `ALIAS_POLICY_SYNC_INTERVAL` for `sync_interval`:

```
enabled = true;
api_key = "<your-api-key>";
hostname = "<your-hostname>";
sync_interval = <your-sync-interval>;
```

If `ALIAS_POLICY_SYNC_INTERVAL` is unset or empty, the setup hook writes `300`.

| Option | Default | Description |
|---|---|---|
| `api_key` | *(required)* | Mailcow read-only API key |
| `hostname` | *(required)* | Mailcow hostname for API requests |
| `sync_interval` | `300` | Seconds between API syncs |
| `policy_file` | `/etc/rspamd/local.d/list_policies.json` | Path to the disk cache file |

If `ALIAS_POLICY_SYNC_INTERVAL` is set to an invalid non-empty value, the setup hook logs a warning and writes `300` instead.

## File Locations

| File | Path | Description |
|---|---|---|
| Lua module | `/etc/rspamd/plugins.d/alias_policy.lua` | Rspamd prefilter that syncs and enforces policies |
| Include wrapper | `/etc/rspamd/rspamd.conf.local` | Generated `alias_policy {}` block that includes the module config |
| Module config | `/etc/rspamd/local.d/alias_policy.conf` | Generated module options (`enabled`, `api_key`, `hostname`, `sync_interval`) |
| Policy cache | `/etc/rspamd/local.d/list_policies.json` | Cached policy data for cold starts (auto-managed) |

## Logging

The module now uses Rspamd log levels based on the kind of event being recorded instead of writing everything at `error`. Each message is still prefixed with `alias_policy:` for easy filtering.

In Mailcow, successful alias matches are normally driven by the original recipient stored in `ORCPT`, so a policy check may still succeed even when the visible SMTP recipient has already been rewritten to the alias destination mailbox.

Mailcow commonly runs Rspamd with a minimum log level of `error`, so by default you will only see error-level entries. To see warning or notice entries from this module, lower Rspamd's log threshold accordingly.

| Event | Log Level | What's Logged |
|---|---|---|
| Configuration and runtime failures | `error` | Missing required config at startup, map registration failures, API failures, parse failures, and file write failures |
| Invalid alias policy metadata | `warning` | Aliases skipped because `private_comment` contains an unrecognized policy or an invalid `membersonly` moderator list |
| Startup, sync, and enforcement activity | `notice` | Whether cached policies were reused, whether an initial sync ran, API response size, unchanged policy-cache skips, how many policies were parsed from the API, how many were loaded from the map, when the policy cache file was written, per-message policy checks, ALLOW decisions, and REJECT decisions |

View logs in the Rspamd container:
```bash
docker compose logs rspamd-mailcow | grep 'alias_policy:'
```
