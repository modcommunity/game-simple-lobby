This is a **lobby** built on TMC's **Dot** collection. It is what a server runs when it is not running anything else, and it is the smallest thing that still exercises joining, membership, replication and chat.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The Staging Area
A lobby. You walk about in a small 2D room, you can see who else is in it, and you can
talk to them.

Part of the [dot-*](../NOTES.md) family. It is the game a
[dot-server](../dot-server) runs when it is not running anything else — the staging area
a player lands in, and the place they wait while an operator changes the game under them.

```bash
godot --path .                                   # the launcher
godot --path . -- --offline                      # an empty room, no server
godot --path . -- --connect 127.0.0.1:27085      # straight in

godot --headless --path . res://examples/dedicated.tscn -- --serve
```

Mouse or WASD walks. Enter talks, Escape stops talking.

## What it is for

Three things, and the third is the reason it exists at all.

**A place to be that is not a game.** A server with no game loaded is a legitimate thing
to run and dot-server has always supported it; what it did not have was anything to look
at. A player who connects and sees nothing cannot tell that from a broken server.

**The thing a generic client shell downloads first.** This is the game shipped as a
dot-cloud pack in [dot-server-setup-test](../dot-server-setup-test): a browser client
connects, is sent here, mounts it, and is standing in a room without knowing what a room
is. `changelevel` then moves them somewhere else and back.

**A small enough game that the platform is what is being tested.** There is no scoring,
no combat, no rounds and no content beyond a rectangle: what is left is admission,
membership, replication, prediction and chat, which is exactly the set of things every
other game also has to get right.

## What is in it

| | |
| --- | --- |
| **The room** | A bounded rectangle, smaller than a screen. Everybody sees all of it. |
| **Walking** | dot-2d's top-down motor, deterministic, predicted by the client and reconciled by the server. |
| **Chat** | dot-server's, routed and sanitised there, drawn here as a log and as a bubble over the speaker's head. |
| **The roster** | Everybody in the room, oldest first, with how long they have been here. |
| **Join and leave** | Announced in the log and in a fading feed. |

No art, no audio, no fonts: everything is a rectangle, a circle or a string, the same way
[dot-ui](../dot-ui) ships no art and [dot-2d](../dot-2d) draws nothing.

## Validating

```bash
tools/check.sh                # parse every script, then run every example
tools/check.sh --parse        # the parse pass on its own
```

177 checks across four suites:

| | | |
| --- | --- | --- |
| `examples/headless_room.tscn` | 31 | the room alone: membership, walls, determinism |
| `examples/headless_net.tscn` | 59 | the wire and the netcode, over a lossy loopback |
| `examples/dedicated.tscn` | 40 | a real `DotServer` with the module in it |
| `examples/sandbox.tscn` | 41 | **two real clients, over real sockets** |

The last one is the one that matters. See CLAUDE.md.

## Development setup

```bash
cd godot/game-simple-lobby
for pair in dot_core:dot-core dot_2d:dot-2d dot_net:dot-net \
            dot_server:dot-server dot_ui:dot-ui; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done
```

The links are gitignored: a shipped build copies the addon folders in instead.
