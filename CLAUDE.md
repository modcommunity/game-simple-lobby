# game-simple-lobby

A lobby: a small 2D room with chat, a roster and join/leave notices. Read
`../../CLAUDE.md` first for the family-wide rules; this file is what is specific to this
game.

## Why this project exists

**A server with no game is a legitimate thing to run and there was nothing to look at.**
dot-server's own comment beside the empty-scene branch calls a scene-less server
"legitimate for a lobby", and until now no lobby existed. A player who connects to one and
sees a blank screen cannot distinguish it from a broken server.

**It is the first game meant to be delivered rather than shipped.** game-arena, game-blob
and dot-2d-hungry all ship inside their own build, so `changelevel` has never sent a client
to fetch a map and dot-server's content sync has never run end to end. This one is small
enough to be a pack — no art, no audio, no fonts — and it is what
[dot-server-setup-test](../dot-server-setup-test)'s client shell mounts.

**It is the smallest thing that still exercises the whole platform.** No scoring, no
rounds, no combat, no items. What is left is admission, membership, replication,
prediction and chat, and every one of those is something every other game also has to get
right.

## Chat is dot-server's, and nothing here re-implements it

`DotChatManager` routes, sanitises, flood-limits and permission-filters every message, and
every client already receives one through `DotClientLink.chat_received`. This game adds no
chat message to its own wire format.

That is a deliberate refusal, not an omission. A second path would be a second set of rules
to keep in step, and the one that skipped the filter would be the one that leaked admin
chat to everybody — or that let a zero-width character through and rendered a name
backwards. `examples/sandbox.tscn` checks the sanitising from this side for that reason:
not because dot-server's own suite does not, but because the thing worth checking is that
this game did not route around it.

The bubble over somebody's head is drawn from the same payload the log is. One path, so a
bubble can never say something the log does not.

## Everybody is always relevant, and that is what caps the room

`DotNetIdentity.always_relevant` is set on every occupant. A room is smaller than a screen
and the roster names every person in it anyway, so hiding a position would save thirteen
bytes a snapshot and produce a name in the list with nobody under it.

`RoomContent.MAX_OCCUPANTS` is what makes that affordable and it is the only reason the cap
exists. Past it a lobby needs interest management, at which point it is not a lobby.

## The bugs this project found

Every one of these parsed cleanly and none produced an error. Four are in other projects
and none was reachable from that project's own suite.

**In dot-net — the input timeline did not include the flight time.**
`DotNetClock._target_lead()` returned `input_margin_ticks` alone. A command stamped for
tick N has to be in the server's hands *before* it simulates N and spends half a round trip
getting there, so on any connection with more than about 30 ms of one-way latency every
input landed after its tick had passed, `DotNetInput.Buffer` discarded all of them as late,
and the server repeated whatever command it last had. The player moved perfectly on their
own screen and nowhere else, and the position was corrected back a few times a second, so
it read as a broken predictor. The class documentation on `input_margin_ticks` had said
"on top of half the round trip" the whole time; that half was never added.

It was unreachable from either existing netcode suite because **dot-2d-hungry's loopback
delivers everything in the same flush** — zero latency — and hand-stamps a lead of 2 with a
comment saying `DotNetClock` is what does this in a real deployment. This project's
loopback is the first in the family that delays a packet, and it delays in *ticks*, because
a wall-clock delay measured against a loop that advances a tick per frame is not a delay at
all: a headless run does several hundred frames a second, so a "60 ms" latency swallows
every packet for the first fifty ticks. The first version did that and the symptom was 240
units of drift, which reads as a broken predictor and is a broken clock.

**In dot-net — nothing ever calls `DotNetStats.note_rtt`.** It is a public method with a
median and a mean-absolute-deviation behind it, and `DotNetManager.receive_snapshot` reads
`stats.rtt_percentile(0.5)` on every snapshot to feed the clock. No caller anywhere in
dot-net writes a sample, so it always reads zero — dot-net never touches a transport and
cannot measure it. The host has to feed it, and until this project nothing knew that.
`RoomBridge.rtt_source` is the seam, pointed at `DotClientLink.ping_ms()` on a real client
and at the loopback's own known delay in a test. Fixing the lead without also fixing this
would have changed nothing.

**In dot-net — the first sample with a real round trip was treated as drift.** Once
`_synced` is set, `sync_from_server` corrects proportionally at up to 5% a second, and a
six-tick error takes two seconds to close — two seconds during which every input is
discarded. The first anchor usually arrives before anything has measured the link, so it is
not drift from that: it is a different measurement, and it is now adopted outright, once.

**Here — `_net_state_applied` moved the node on a predicted entity.**
`DotNetManager.receive_snapshot` calls it, through `read_state`, *before* it calls
`DotNetPredictor.reconcile` — and the first thing reconcile does is capture the node as
"what the client is currently showing", to measure how wrong the prediction was. Writing
the server's position there first makes that capture the server's position, so the measured
error is the entire replay distance rather than the disagreement. `correction_rate()` read
0.909, every reconciliation logged a snap, and the simulation was right the whole time,
which is what made it hard to see. **`HungryPieceNet` has the same line.**

**Here — the peer map was written after the world was told.** `RoomWorld.add_occupant`
emits `occupant_joined` synchronously and the handler builds the `DotNetIdentity` from
`peer_for_occupant`, so writing the map afterwards gave every entity `owner_peer_id = 0`.
Nothing errors: the entity replicates perfectly and is simply owned by nobody, so
`DotNetManager._apply_input` hands the peer's commands to an empty list.

**Here — the scene-instantiated world never had `setup()` called.** `DotGameManager`
instantiates a game's scene and nothing in dot-server knows a world needs setting up, so
the documented way of loading this game produced a world with no arena that registered no
service, and the module refused to load with "No RoomWorld is registered". The scene loaded
perfectly. `auto_setup` is on by default now, and `setup()` is idempotent.

**Here — the descriptor named an absolute client scene.** Exactly the trap dot-server's own
CLAUDE.md describes: `DotClientLink._resolve_scene` refuses every absolute path outside
dot-cloud's mount, correctly, so the client refused it, never reported loaded, sat in
`LOADING` sending no heartbeats and was timed out for being idle. A game shipped inside its
build must name *no* client scene. `RoomModule.game_descriptor()` now takes a manifest URL
and produces either shape, because both are real deployments of this game.

**Here — a `Dot2DState` position quantisation step larger than dot-net's reconcile
epsilon.** 20 bits over ±8192 is 0.016 units; the default epsilon is 0.01. Every single
reconciliation therefore measured the quantisation as an error and `correction_rate()` read
~1.0 whether or not anything was wrong — so the one number that says whether prediction is
working said nothing. `RoomContent.net_config()` sets 0.05, which is `Dot2DState.matches`'s
own tolerance, chosen for the same reason. **Any dot-2d game on dot-net has this.**

**In dot-net — `Array.sort()` on a `StringName` does not sort lexicographically.**
Godot compares StringNames by their interned pointer, so `DotNetMessageRegistry.seal()`
gave the same message type different wire ids on two peers and hashed two different
schemas. Found from `dot-server-setup-test`'s browser client, which is the first peer in
this family that is a separate program; every suite here runs both ends in one process and
shares one intern table. `headless_net` now asserts the order is lexicographic, which
catches it without two processes.

**Here — `set_anchors_preset` does not set offsets.** The anchors describe how a rectangle
should follow its parent and change nothing until something resizes it, so a `Control`
built in code keeps the zero size it was created with. Every child then lays out inside
nothing and the whole interface is invisible while being, by every property, correctly
configured. The chat log, the roster and the feed were all built, populated and drawn at
size zero.

**Here — the leave broadcast went to the peer that had left.** `remove_peer` erased the
peer from the ready set after telling the world, and telling the world fires
`occupant_left` synchronously. Harmless, and it put "Attempt to call RPC with unknown peer
ID" in the log of every single disconnect — which is where somebody looks when something
else is wrong.

## The suites, and which one matters

```bash
tools/check.sh                # all four, after a parse pass
```

| | | |
| --- | --- | --- |
| `headless_room` | 31 | the room alone. Membership, walls, and two worlds replaying the same commands bit-identically |
| `headless_net` | 59 | every encoder against its decoder, then a session over a lossy delaying loopback |
| `dedicated` | 40 | a real `DotServer`, a real module, a real WebSocket listener |
| `sandbox` | 41 | **a real server and two real clients, over real sockets, in one process** |

**`sandbox` is the one that matters and the slowest to write.** It is the only place
dot-server's signon, the RPC node paths, dot-server's chat and this game's netcode run at
once, and the only place two people are in the same room — which is the thing a multiplayer
game must do and the thing every per-observer decision is trivially correct about with one
observer. Three of the bugs above are its.

It runs three `MultiplayerAPI` instances in one tree, scoped by
`SceneTree.set_multiplayer`, and every one of the three link nodes is named `Server`,
because Godot routes an RPC by the receiver's node path relative to its API root. The name
is the routing, not a description.

Each suite counts **sections entered against sections that ran to their last line** and
fails when they differ. A runtime error inside a section aborts that function and nothing
says so: the checks that already ran still print ok, the ones after it never happen, and
the total at the bottom cannot reveal a check that never ran.

## Where a game plugs in

| To change | Where |
| --- | --- |
| The room's size, speed, capacity, palette | `RoomContent` — constants, because both ends read them and a mismatch is silent |
| The netcode's settings | `RoomContent.net_config()`, in one place so three call sites cannot drift |
| Where a command comes from | `RoomInput.command_source` — bots, demo playback, tests |
| How somebody is drawn | `RoomRenderer`, which reads the world and never writes to it |
| Where the round trip is measured | `RoomBridge.rtt_source` |
| Whether the world sets itself up | `RoomWorld.auto_setup` |
| Which link a client uses | `RoomClient.link`, assigned before it enters the tree |

## Things deliberately not here

- **Interest management.** Everybody is always relevant, and `MAX_OCCUPANTS` is the price.
- **Lag compensation.** Nothing here is disputed, so rewinding would change an outcome
  nobody is arguing about. Off, explicitly, in `RoomContent.net_config()`.
- **Persistence.** Nobody's position outlives their session, and a name that did would be a
  profile — which is dot-user's.
- **Avatars.** `dot-user-avatar` would draw a rider on top of a circle exactly the way
  dot-2d-hungry does, and it is the one piece of this that has already been proven
  elsewhere.
- **A Host button.** A browser tab cannot listen, and offering a control that fails on the
  platform this game exists for is worse than not offering it.
- **Audio.** dot-2d-hungry generates its whole bank arithmetically; there is nothing here
  worth hearing.
