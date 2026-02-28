# Appservice Registration on Continuwuity

Registering Kazarma as an appservice on [Continuwuity](https://continuwuity.org/) (and its upstream [conduwuit](https://conduwuit.puppyirl.gay/)) has several non-obvious pitfalls. This page documents them so you don't have to rediscover them.

## The core problem: no file-based registration path

Most Matrix homeservers (Synapse, Dendrite) accept a path to an appservice registration YAML file via config. Continuwuity does not. Despite `CONTINUWUITY_APPSERVICES_PATH` being a plausible env var, it is not implemented — the server will log a warning and ignore it:

```
WARN Config parameter "appservices_path" is unknown to conduwuit, ignoring.
```

Continuwuity stores appservice registrations in its RocksDB database. The only way to register one is via the admin console command `appservices register`.

## Registering via `admin_execute` at startup

The running server locks the RocksDB file, so you cannot spin up a second instance to run the registration command. Instead, use the `admin_execute` config key, which runs console commands during startup before the server begins serving requests.

Create a separate TOML file (e.g. `execute-appservice.toml`):

```toml
[global]
admin_execute_errors_ignore = true
admin_execute = [
  '''appservices register
```yaml
id: "Kazarma"
url: "http://kazarma:4000"
as_token: "<your-as-token>"
hs_token: "<your-hs-token>"
sender_localpart: "_kazarma"
namespaces:
  users:
    - exclusive: true
      regex: '@_kazarma:example\.org'
    - exclusive: false
      regex: '@_ap_.+:example\.org'
  aliases: []
  rooms: []
```'''
]
```

Then start the server once with this config file instead of the normal one:

```bash
/sbin/conduwuit -c /path/to/execute-appservice.toml
```

After it starts and executes the command, stop it and restart with your normal config. The registration persists in RocksDB.

### Pitfall 1: `[global]` section is required

All Continuwuity config keys must be inside a `[global]` section. Without it, the server rejects the file:

```
invalid type: boolean true, expected a map
```

### Pitfall 2: TOML string format for the command body

The `appservices register` command expects its argument to be a YAML code block (triple-backtick fenced). Embedding backticks inside a regular TOML string requires escaping. Use TOML **literal multi-line strings** (`'''...'''`) instead — they pass content through with no escape processing:

```toml
admin_execute = [
  '''appservices register
```yaml
... your YAML here ...
```'''
]
```

Note the structure: the opening `'''` is on the same line as the command name, and the closing `'''` immediately follows the closing ` ``` ` of the YAML block.

### Pitfall 3: YAML regex escaping in single quotes

Namespace regexes contain `\.` (escaped dot). In YAML **double-quoted** strings, `\.` is an invalid escape sequence and the parser will reject it:

```yaml
# WRONG — YAML double-quoted strings don't allow \.
regex: "@_ap_.+:example\.org"
```

Use YAML **single-quoted** strings, which perform no escape processing:

```yaml
# CORRECT
regex: '@_ap_.+:example\.org'
```

### Pitfall 4: duplicate appservice ID from a previous attempt

If you've attempted registration before (e.g. with a different ID casing), the old entry stays in the DB and its tokens are still considered "in use." Trying to register again fails with:

```
Token is already used by appservice 'kazarma'
```

Unregister the old entry first by adding it to `admin_execute` before the register command:

```toml
admin_execute = [
  'appservices unregister kazarma',
  '''appservices register
... YAML ...
'''
]
```

`admin_execute_errors_ignore = true` prevents the unregister command from aborting startup if the entry doesn't exist.

## Namespace configuration: bot user must be exclusive

Continuwuity only routes room events to an appservice if the appservice's bot user appears in the **exclusive** namespace. A namespace covering only puppet users (e.g. `@_ap_.*`) is not enough — membership events for the bot itself (`@_kazarma:example.org`) will never be forwarded, so the bot will never receive invitations and never join rooms.

The registration YAML must include a separate exclusive entry for the bot user:

```yaml
namespaces:
  users:
    - exclusive: true
      regex: '@_kazarma:example\.org'   # bot user — must be exclusive
    - exclusive: false
      regex: '@_ap_.+:example\.org'     # AP puppet users
```

Once the bot is a joined member of a room, Continuwuity forwards **all** events in that room to the appservice, regardless of namespace.

## Full working example

Below is the complete `execute-appservice.toml` used to register Kazarma on a Continuwuity instance at `example.org`, replacing the Kazarma container's hostname with `kazarma`:

```toml
[global]
admin_execute_errors_ignore = true
admin_execute = [
  'appservices unregister Kazarma',
  '''appservices register
```yaml
id: "Kazarma"
url: "http://kazarma:4000"
as_token: "diiimbcvxz391bxyJWY9SaJy78ugYWZls3fXFtNKdHM"
hs_token: "cctLJQfL6eD-BnyXCPFmKtiG9LXYFUDbp7qGmlV6_tA"
sender_localpart: "_kazarma"
namespaces:
  users:
    - exclusive: true
      regex: '@_kazarma:example\.org'
    - exclusive: false
      regex: '@_ap_.+:example\.org'
  aliases: []
  rooms: []
```'''
]
```

Replace the tokens with the values from your `kazarma-registration.yaml` and `example\.org` with your actual domain (remember single quotes in YAML to avoid `\.` parse errors).
