extends Node

## A real server and two real clients, over real sockets, in one process.
##
## [codeblock]
## godot --headless --path . res://examples/sandbox.tscn
## godot --headless --path . res://examples/sandbox.tscn -- --verbose
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The one that matters, and the slowest to write.[/b] It is the only place dot-server's
## signon, the RPC node paths, dot-server's chat and this game's netcode all run at once,
## and it is the only place two people are in the same room — which is the thing a
## multiplayer game must do and the thing every per-observer decision is trivially correct
## about with one observer.
##
## [b]Three MultiplayerAPI instances in one process.[/b] There is a single
## [member SceneTree.multiplayer] and three peers here want it, so each half gets its own
## through [method SceneTree.set_multiplayer], scoped to its own subtree. dot-platform's
## sandbox proved the mechanism; the catch it also proved is that RPCs are routed by node
## path *relative to each API root*, so the paths have to line up on both sides — which is
## why every one of the three link nodes is named `Server`.

const PORT := 27086
const SERVER_DIR := "user://room_sandbox"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null

var _client_side: Node = null
var _link: DotClientLink = null
var _client: RoomClient = null
var _heard: Array[Dictionary] = []

var _other_side: Node = null
var _other_link: DotClientLink = null
var _other: RoomClient = null
var _other_heard: Array[Dictionary] = []


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby sandbox")

	DotPaths.remove_tree(SERVER_DIR)

	if await _build():
		if await _test_join():
			await _test_room()
			await _test_chat()
			await _test_two_people()
			await _test_walking()
			await _test_leaving()

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
## A deadline rather than a fixed number of frames: a signon over loopback is several
## round trips, and "a hundred frames is surely enough" is a check that passes on an idle
## box and fails on a busy one.
func _until(condition: Callable, seconds: float = 12.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _settle(frames: int = 30) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


# --- Building --------------------------------------------------------------

func _build() -> bool:
	print("")
	print("bringing the sandbox up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), server_side.get_path()
	)
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_check(
		get_tree().get_multiplayer(server_side.get_path())
			!= get_tree().get_multiplayer(_client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)

	if not await _build_server(server_side):
		return false

	# Named "Server", which looks wrong and is not. Godot addresses an RPC by the
	# receiver's node path relative to its MultiplayerAPI root, so a call from the
	# server's node at ServerSide/Server arrives addressed to "Server" and is looked up
	# under the client's root. Give the client's node any other name and every RPC fails
	# with "Node not found: Server" — the handshake included, whose only symptom is a
	# timeout.
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Ada"
	_client_side.add_child(_link)

	return true


func _build_server(server_side: Node) -> bool:
	var config := DotServerConfig.new()
	config.hostname = "room sandbox"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# No dot-auth in this tree, so everybody is a guest with a per-device id through
	# [DotGuestIdentity]. That is the simplest deployment shape there is, and the family's
	# own rule says a path only one shape reaches is a path nothing has run.
	_check(
		not DotRegistry.has(&"dot_auth_server"),
		"with no dot-auth, so everybody arrives as a guest"
	)

	_server.games.add_game(RoomModule.game_descriptor())

	var loaded: DotResult = await _server.games.change_game(RoomModule.GAME_ID, "boot")

	if not _check(loaded.ok, "the room loads", str(loaded.error)):
		return false

	var module := _server.modules.load_module("res://game/room_module.gd")
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	for link in [_other_link, _link]:
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("shutdown")

	if _server != null and is_instance_valid(_server):
		_server.shutdown("sandbox finished")


func _module() -> RoomModule:
	return _server.modules.get_module("room") as RoomModule


## Instantiates the client scene against a given link.
##
## The link is assigned *before* the node enters the tree, because [method Node._ready] is
## where the client wires itself up — and a client that found no link would stand up an
## offline room instead of joining this one, silently and quite convincingly.
func _make_client(parent: Node, link: DotClientLink) -> RoomClient:
	var packed: Variant = load("res://scenes/room_client.tscn")
	var client := (packed as PackedScene).instantiate() as RoomClient
	client.link = link
	parent.add_child(client)
	return client


# --- Sections --------------------------------------------------------------

func _test_join() -> bool:
	_section("a client connects")

	var spawned := [false]
	var refused := [""]

	# Captured through Arrays, not bools. GDScript lambdas capture locals by value, so a
	# flag set inside a handler stays false outside it — and the test reports a failure
	# for a signal that fired perfectly.
	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: refused[0] = reason)
	_link.chat_received.connect(func(payload: Dictionary) -> void:
		_heard.append(payload)
	)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(func() -> bool: return spawned[0] or refused[0] != "")

	if not _check(admitted, "and finishes signon", "refused: %s" % refused[0]):
		_done()
		return false

	_check(refused[0] == "", "without being refused")
	_check(_server.sessions().size() == 1, "the server has one session")

	# The room ships inside the build, so the descriptor names no manifest and
	# [method DotGameDescriptor.client_scene_or_scene] hands the client the empty string —
	# the documented "you already have it" path. A server that fell back to its own
	# absolute scene path would have the client refuse it and time out in LOADING.
	_check(
		_link.phase == DotClientLink.Phase.PLAYING,
		"and is playing rather than stuck loading (%s)" % _link.phase
	)

	_client = _make_client(_client_side, _link)

	var told := await _until(func() -> bool:
		return _client.bridge != null and _client.bridge.local_occupant_id != 0
	)

	_check(told, "the client scene is told who it is")
	_done()
	return told


func _test_room() -> void:
	_section("the room, from the client's side")

	await _settle(60)

	var mine := _client.bridge.local_occupant_id
	var session := _server.sessions()[0]

	_check(
		mine == session.userid,
		"the client's id is the server's session id (%d, %d)" % [mine, session.userid]
	)
	_check(
		_client.world.occupant_count() == 1,
		"and its room has one person in it (%d)" % _client.world.occupant_count()
	)

	var me := _client.world.occupant_for(mine)
	_check(me != null and me.is_local, "who is marked as the local one")
	_check(
		me != null and me.display_name == "Ada",
		"with the name the link was given (%s)"
			% (me.display_name if me != null else "-")
	)
	_check(
		_client.bridge.entity_count() == 1,
		"and one replicated entity behind them"
	)

	# The one thing a mismatch is completely silent about: every position would still
	# decode and every id would still match, and everybody would simply be standing
	# somewhere else.
	_check(
		_client.world.arena.bounds.size.is_equal_approx(
			_module().world.arena.bounds.size
		),
		"both ends agree how big the room is"
	)
	_done()


func _test_chat() -> void:
	_section("chat")

	# dot-server's, not this game's: routed, sanitised, flood-limited and
	# permission-filtered there, and delivered through [signal DotClientLink.chat_received].
	_link.send_chat("hello from Ada")

	var heard := await _until(func() -> bool:
		for payload in _heard:
			if String(payload.get("text", "")) == "hello from Ada":
				return true
		return false
	)

	_check(heard, "a line the client sent comes back to it")

	var me := _client.world.occupant_for(_client.bridge.local_occupant_id)
	_check(
		me != null and me.bubble_text == "hello from Ada",
		"and becomes a bubble over the person who said it"
	)

	var on_server := _module().world.occupant_for(_client.bridge.local_occupant_id)
	_check(
		on_server != null and on_server.bubble_text == "hello from Ada",
		"on the server too, which is what `room_who` reports from"
	)

	# Sanitising is dot-server's and is checked there; what matters here is that this game
	# did not route around it.
	_link.send_chat("a​b")
	await _settle(30)

	var last := String(
		(_heard[_heard.size() - 1] as Dictionary).get("text", "")
	) if not _heard.is_empty() else ""
	_check(
		not last.contains("​"),
		"and a zero-width character is stripped before anybody sees it (%s)" % last,
		"used to spoof names and hide text; a second chat path would skip this"
	)
	_done()


## A second person, over a second socket, in a third MultiplayerAPI.
##
## Everything before this is one client: it proves the signon, the RPC paths and the
## netcode, and proves nothing at all about whether two people can see each other. The
## roster, the join broadcast and the entity mirroring are all per-observer, and every one
## of them is trivially correct with one observer.
func _test_two_people() -> void:
	_section("a second person")

	_other_side = Node.new()
	_other_side.name = "OtherSide"
	add_child(_other_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _other_side.get_path()
	)

	_other_link = DotClientLink.new()
	# "Server", the same as the first one and the same as [DotServer]. The name is the
	# routing, not a description.
	_other_link.name = "Server"
	_other_link.player_name = "Grace"
	_other_side.add_child(_other_link)

	var spawned := [false]
	_other_link.spawned.connect(func() -> void: spawned[0] = true)
	_other_link.chat_received.connect(func(payload: Dictionary) -> void:
		_other_heard.append(payload)
	)

	var connecting: DotResult = await _other_link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "it connects", str(connecting.error)):
		_done()
		return

	if not _check(await _until(func() -> bool: return spawned[0]), "and completes signon"):
		_done()
		return

	_check(_server.sessions().size() == 2, "the server has two sessions")

	_other = _make_client(_other_side, _other_link)

	var told := await _until(func() -> bool:
		return _other.bridge != null and _other.bridge.local_occupant_id != 0
	)

	if not _check(told, "and the second client is told who it is"):
		_done()
		return

	var mine := _client.bridge.local_occupant_id
	var theirs := _other.bridge.local_occupant_id

	_check(mine != theirs, "the two have different ids (%d and %d)" % [mine, theirs])

	var both_seen := await _until(func() -> bool:
		return _client.world.occupant_count() == 2 \
			and _other.world.occupant_count() == 2
	)

	_check(
		both_seen,
		"each of them can see the other (%d and %d in the room)"
			% [_client.world.occupant_count(), _other.world.occupant_count()],
		"the roster and the join broadcast are per-observer and are both trivially "
		+ "correct with one observer"
	)

	var grace_to_ada := _client.world.occupant_for(theirs)
	var ada_to_grace := _other.world.occupant_for(mine)

	_check(
		grace_to_ada != null and grace_to_ada.display_name == "Grace",
		"by name, on the first client (%s)"
			% (grace_to_ada.display_name if grace_to_ada != null else "-")
	)
	_check(
		ada_to_grace != null and ada_to_grace.display_name == "Ada",
		"and on the second (%s)"
			% (ada_to_grace.display_name if ada_to_grace != null else "-")
	)
	_check(
		grace_to_ada != null and not grace_to_ada.is_local,
		"and somebody else's occupant is not marked local"
	)

	# Chat from the second reaches the first, through the server, and becomes a bubble
	# over the right head — which is the whole of what a lobby is.
	_other_link.send_chat("hello from Grace")

	var relayed := await _until(func() -> bool:
		for payload in _heard:
			if String(payload.get("text", "")) == "hello from Grace":
				return true
		return false
	)

	_check(relayed, "and what one says reaches the other")
	_check(
		grace_to_ada != null and grace_to_ada.bubble_text == "hello from Grace",
		"over the right head"
	)
	_done()


## Somebody walking, seen from the other client.
##
## This is the path nothing but two real clients reaches: the input goes out over a socket,
## the server simulates it, the snapshot comes back to a *different* peer, and the
## interpolator has to put the smoothed value somewhere the renderer reads. Both other
## games in this family shipped a version where it did not.
func _test_walking() -> void:
	_section("walking, seen by somebody else")

	var theirs := _other.bridge.local_occupant_id
	var seen_by_ada := _client.world.occupant_for(theirs)

	if not _check(seen_by_ada != null, "the first client can see the second"):
		_done()
		return

	var before := seen_by_ada.position()

	# Through the second client's own sampler, so this is the whole real path: sample,
	# quantise, send over a socket, simulate on the server, snapshot to a *different*
	# peer, interpolate, draw. Driving `client_tick` by hand instead would race the
	# client's own `_physics_process`, which is sampling "stopped" on the same frames — so
	# the two would take turns and the person would shuffle.
	var target := _other.world.arena.bounds.get_center()
	var command := Dot2DCommand.new()
	command.move = (target - _other.world.occupant_for(theirs).position()).normalized()
	_other.input.command_source = func() -> Dot2DCommand: return command

	await _settle(180)

	_other.input.command_source = Callable()

	var on_server := _module().world.occupant_for(theirs)

	_check(
		on_server != null and on_server.position().distance_to(before) > 30.0,
		"the server moved them (%.0f units)"
			% (on_server.position().distance_to(before) if on_server != null else 0.0),
		"an input stamped for a tick the server has passed is discarded as late, for "
		+ "ever, with no error on either end"
	)
	_check(
		seen_by_ada.position().distance_to(before) > 30.0,
		"and the other client sees it (%.0f units)"
			% seen_by_ada.position().distance_to(before),
		"an interpolated value written into a property nothing reads looks exactly like "
		+ "an interpolator that does not work"
	)
	_check(
		on_server != null
			and seen_by_ada.position().distance_to(on_server.position()) < 60.0,
		"within %.0f units of where the server has them"
			% (seen_by_ada.position().distance_to(on_server.position())
				if on_server != null else -1.0)
	)
	_done()


func _test_leaving() -> void:
	_section("leaving")

	_other_link.disconnect_from_server("done")

	var noticed := await _until(func() -> bool:
		return _client.world.occupant_count() == 1
	)

	_check(noticed, "the first client is told the second left")
	_check(
		_module().world.occupant_count() == 1,
		"and the server's room has one person in it"
	)
	_check(
		_client.bridge.entity_count() == 1,
		"with one entity, not a ghost (%d)" % _client.bridge.entity_count()
	)
	_check(
		_server.sessions().size() == 1,
		"and one session (%d)" % _server.sessions().size()
	)
	_done()
