extends Node

## A real [DotServer] with the room loaded into it, listening for browser clients.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn            # self-test
## godot --headless --path . res://examples/dedicated.tscn -- --serve # run one
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The WebSocket listener is the point.[/b] A browser has no UDP and Godot's web
## template does not ship `ENetMultiplayerPeer` at all, so a server that expects browser
## clients listens on WebSocket — and then, today, *all* of its clients do.
## [member DotTransportAuto.require_web_clients] defaults to true for exactly this reason,
## and this is the deployment shape a lobby is for.
##
## It does not connect a client: `examples/sandbox.tscn` does that, over a real socket.

const PORT := 27085
const SERVER_DIR := "user://room_dedicated"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	var serving := "--serve" in OS.get_cmdline_user_args()

	print("game-simple-lobby dedicated server")

	if not serving:
		DotPaths.remove_tree(SERVER_DIR)

	var built := await _build(serving)

	if serving:
		if built:
			print("")
			print("listening on ws://0.0.0.0:%d — ctrl-c to stop" % PORT)
			for line in _server.status_lines():
				print("  %s" % line)
		return

	if built:
		_test_world()
		_test_module()
		_test_commands()
		_test_joining()
		_test_transport()
		_test_unload()

	_teardown()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


## Waits for a condition, or gives up. Returns whether it happened.
##
## A deadline rather than a fixed number of frames: how many frames the module needs
## depends on what else the machine is doing, and "twenty frames is surely enough" is a
## check that passes on an idle box and fails on a busy one.
func _until(condition: Callable, seconds: float = 6.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _module() -> RoomModule:
	return _server.modules.get_module("room") as RoomModule


func _world() -> RoomWorld:
	return DotRegistry.get_node_service(RoomWorld.SERVICE) as RoomWorld


# --- Boot ------------------------------------------------------------------

func _build(serving: bool) -> bool:
	print("")
	print("booting")

	var config := DotServerConfig.new()
	config.hostname = "a room"
	config.port = PORT
	config.bind_address = "0.0.0.0" if serving else "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# A lobby is the one thing that should never hibernate: it is where people wait, and a
	# server that stops ticking when it empties stops moving the last person out of it.
	config.hibernate_when_empty = false
	# The addon ships a default `server.cfg` that the search path would find, which is
	# correct layering and would make this test assert against whatever that file says.
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	_server.games.add_game(RoomModule.game_descriptor())

	var loaded: DotResult = await _server.games.change_game(RoomModule.GAME_ID, "boot")

	if not _check(loaded.ok, "the room's scene loads", str(loaded.error)):
		return false

	var module := _server.modules.load_module("res://game/room_module.gd")
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	if _server == null or not is_instance_valid(_server):
		return

	_server.shutdown("test over")
	remove_child(_server)

	# Freed rather than queued. A `queue_free` on the last line before `quit()` is a free
	# that never happens: the deferred call is dropped with the tree, and every node under
	# it is reported as leaked at exit — which is true, and says nothing about a cycle.
	_server.free()


# --- Sections --------------------------------------------------------------

func _test_world() -> void:
	_section("the room")

	var world := _world()

	_check(world != null, "the game scene registered one")

	if world == null:
		_done()
		return

	_check(world.is_authority, "and it is the authority")
	_check(world.occupant_count() == 0, "with nobody in it yet")
	_check(
		world.arena.bounds.size.is_equal_approx(RoomContent.ROOM_EXTENT * 2.0),
		"at the size RoomContent says"
	)
	_done()


func _test_module() -> void:
	_section("the module")

	_check(_server.modules.has_module("room"), "is listed among the server's modules")

	var module := _module()
	_check(module != null and module.world == _world(), "and holds the room")
	_check(module != null and module.net != null, "with a netcode manager of its own")
	_check(
		module != null and module.net != null and module.net.is_server,
		"which is the authority"
	)
	_check(
		module != null and module.bridge != null and module.bridge.link != null,
		"and a link where RPCs will find it"
	)
	_check(
		module != null and module.bridge != null
			and module.bridge.link.name == RoomLink.NODE_NAME,
		"named %s, because the name is the routing" % RoomLink.NODE_NAME
	)
	_check(
		module != null and module.bridge != null
			and module.bridge.link.get_parent() == _server,
		"under the server, which the client's half calls by the same name"
	)

	for command in ["room_status", "room_who", "room_net"]:
		_check(
			_server.console.find_command(command) != null, "registered %s" % command
		)

	_check(
		_server.games.find_game(RoomModule.GAME_ID) != null,
		"and its game descriptor is registered, so changelevel can reach it"
	)
	_done()


func _test_commands() -> void:
	_section("its commands")

	for command in ["room_status", "room_who", "room_net"]:
		_check(_server.console.execute(command).ok, "%s runs" % command)

	_done()


## Membership, through the bridge rather than through a socket.
##
## [b]The admission path itself is not faked here.[/b] dot-server's session table is
## private, deliberately, so a test that reached into it would be testing a table it had
## filled in itself — and the two bugs this family has had in exactly this place were both
## about which key the *event* carries. Only a real client can show that, and
## `examples/sandbox.tscn` is where one connects.
##
## What this covers is everything downstream of admission, which is the part a socket
## would only slow down.
func _test_joining() -> void:
	_section("membership")

	var module := _module()
	var added := module.bridge.add_occupant(9, 4242, "Ada")

	_check(added.ok, "the bridge puts somebody in the room", str(added.error))
	_check(_world().occupant_count() == 1, "and the room has one person in it")

	var occupant := _world().occupant_for(4242)
	_check(
		occupant != null,
		"under their session id, not their peer id",
		"a peer id is reassigned on reconnect and the next person would inherit their place"
	)
	_check(
		occupant != null and occupant.display_name == "Ada",
		"with the name they were admitted under"
	)
	_check(
		module.bridge.peer_for_occupant(4242) == 9,
		"and the bridge knows which peer they are (%d)"
			% module.bridge.peer_for_occupant(4242)
	)

	var behaviour := module.bridge.behaviour_for(4242)
	_check(
		behaviour != null and behaviour.identity != null
			and behaviour.identity.owner_peer_id == 9,
		"their entity is owned by that peer",
		"an entity owned by peer 0 replicates perfectly and never receives an input, so "
		+ "the player moves on their own screen and nowhere else"
	)
	_check(
		behaviour != null and behaviour.identity != null
			and behaviour.identity.always_relevant,
		"and is always relevant, because a lobby is smaller than a screen"
	)

	# The chat bubble comes off dot-server's own event, not off this game's wire. Firing it
	# is the whole of that path: the module hooks `player_chat` and looks the speaker up by
	# the `userid` the event carries.
	_server.events.fire("player_chat", {
		"userid": 4242, "name": "Ada", "text": "hello", "team_only": false,
	})
	_check(
		occupant != null and occupant.bubble_text == "hello",
		"a chat line reaches the person who said it, through dot-server's event"
	)

	# And the module survives one for somebody who is not here, which is every system
	# message and every line said between a disconnect and the world noticing.
	_server.events.fire("player_chat", {
		"userid": 999999, "name": "Ghost", "text": "boo", "team_only": false,
	})
	_check(true, "and a line from somebody who is not in the room is ignored")

	module.bridge.remove_peer(9)
	_check(_world().occupant_count() == 0, "removing the peer empties the room")
	_check(
		module.bridge.behaviour_for(4242) == null,
		"and takes their entity, not merely their name"
	)
	_done()


## A browser client needs a WebSocket listener, and dot-core has to be able to make one on
## this build.
##
## Checked through [DotTransportWebSocket] rather than by booting a second server: what can
## go wrong is that the engine build has no WebSocket peer, and that is a property of the
## binary rather than of the configuration.
func _test_transport() -> void:
	_section("browser clients")

	var transport := DotTransportWebSocket.new()
	_check(transport != null, "dot-core can build a WebSocket transport")
	_check(
		transport.supports_web_clients(),
		"which is the one that browser clients can reach"
	)

	var available := transport._is_available()
	_check(
		available.ok,
		"and this engine build has the peer it needs",
		"a build without it cannot serve browser clients at all: %s" % str(available.error)
	)

	# The constraint that shapes the whole deployment: a browser cannot listen, so the web
	# build is a client and the server is somewhere else.
	_check(
		not DotPlatform.is_web(),
		"and this process can listen, because it is not a browser"
	)
	_done()


func _test_unload() -> void:
	_section("unloading")

	_check(_server.modules.unload_module("room").ok, "the module unloads")
	_check(
		_server.console.find_command("room_status") == null,
		"and takes its commands with it",
		"a handler left behind points at a freed object and the console calls it"
	)
	_check(
		_server.modules.load_module("res://game/room_module.gd").ok,
		"and loads again cleanly"
	)
	_done()
