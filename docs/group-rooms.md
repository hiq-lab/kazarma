# Group Rooms (FEP-1b12)

Group rooms let you expose a Matrix room as an ActivityPub `Group` actor on the Fediverse. Once registered, Fediverse users can discover and follow the group without ever joining the Matrix room. Messages posted in the Matrix room are forwarded to all followers as ActivityPub `Note` activities.

## How it works

```
Matrix room  ──────────────────────────────────────────────────────────────────────────
  members post messages
        │
        ▼
  Kazarma bot (in room)
        │  creates AP Create{Note} addressed to followers + Public
        ▼
  AP Group actor  (@_grp_<handle>@<domain>)
        │  delivers to all followers
        ▼
  Fediverse followers (Mastodon, Akkoma, Pleroma, …)
```

Fediverse users can also follow the group via a standard `Follow` activity. Kazarma automatically accepts all follow requests.

## Prerequisites

- Kazarma is running and its appservice is registered in your Matrix homeserver
- You have a Matrix account on the same homeserver as Kazarma

## Setting up a group room

### 1. Create a Matrix room

Create a new room in your Matrix client. It can be public or private — visibility on Matrix does not affect Fediverse discoverability.

### 2. Invite the Kazarma bot

Invite `@_kazarma:<your-domain>` to the room. The bot will join automatically.

### 3. Register the room as a group

Send the following message in the room:

```
!kazarma group <handle>
```

Replace `<handle>` with a short identifier for your group (letters, numbers, hyphens). For example:

```
!kazarma group my-project
```

If successful, Kazarma registers the room and the group actor becomes available on the Fediverse immediately. The handle is permanent — it cannot be changed or reused for a different room.

The group will be discoverable as:

- **WebFinger:** `@_grp_<handle>@<your-domain>`
- **AP actor URL:** `https://<your-domain>/-/_grp_<handle>`

### 4. Share the group address

Tell Fediverse users to search for:

```
@_grp_<handle>@<your-domain>
```

in their client and click Follow.

## Posting to the group

Any message sent in the Matrix room by any member is forwarded to all Fediverse followers. No special syntax is needed — just post normally.

The message appears in followers' timelines as a `Note` from the group actor (`@_grp_<handle>@<your-domain>`), not from the individual Matrix user.

## Limitations

- **One-way bridging:** Fediverse followers receive posts but cannot reply back into the Matrix room (in this release).
- **Text messages only:** Only `m.text` messages are forwarded. Attachments, reactions, and edits are not currently supported for group rooms.
- **No handle reuse:** Once a handle is registered to a room, it cannot be reassigned.
- **Bot must stay in the room:** If the Kazarma bot is removed from the room, forwarding stops. Re-invite it to resume.

## Troubleshooting

**The bot does not join after invitation**
Check that the appservice is correctly registered in your homeserver. The bot's Matrix ID must be in the appservice's exclusive namespace.

**`!kazarma group` produces no response**
Verify the bot is a joined member of the room (not just invited). The homeserver must route room events to the appservice — this requires the bot to have an exclusive namespace entry in the appservice registration.

**Group is not found via WebFinger**
Confirm registration succeeded by fetching the actor URL directly:
```
curl -H "Accept: application/activity+json" https://<your-domain>/-/_grp_<handle>
```
A valid JSON response with `"type": "Group"` means the group is registered and serving correctly.

**Messages are not reaching Fediverse followers**
Check Kazarma's application logs for warnings. A common cause is the follower's server failing to deliver the `Follow` activity, leaving Kazarma with no followers to send to.
