class_name RoomModule
extends DotModule

## Binds a [RoomWorld] and its netcode to a [DotServer].
##
## The only file in this project that names dot-server, and the whole of the dedicated
## server integration: the tick, the join, the leave, and the console surface.
##
## [codeblock]
## server.modules.load_module("res://game/room_module.gd")
## [/codeblock]
##
## [b]The manager outlives the world.[/b] A game change frees the scene the world lives in
## and instantiates the next one; rebuilding the [DotNetManager] with it would reset the
## message ids, the peer records and the clock, which is a disconnect for everybody and
## precisely what changing the game is supposed to avoid. So the manager and the bridge
## are the module's, and [method RoomBridge.rebind] moves the bridge onto the new world.

const CHANNEL := "room.module"

## The game this module serves. Registered so `changegame` and `votemap` mean something.
const GAME_ID := "simple_lobby"

var world: RoomWorld = null
var net: DotNetManager = null
var bridge: RoomBridge = null

## userid -> true, for everybody this module put in the room.
var _joined: Dictionary = {}

var _tick: int = 0


func _module_name() -> String:
	return "room"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "A lobby: walk about, see who is here, talk to them."


func _module_author() -> String:
	return "dot"


## The descriptor a server registers to be able to run this.
##
## Two shapes, and [param manifest_url] is what chooses between them.
##
## [b]Empty — the room ships inside the build.[/b] The scene is a `res://` path and the
## client scene is deliberately [i]left empty[/i]. That is not an omission:
## [method DotClientLink._resolve_scene] refuses every absolute path outside dot-cloud's
## mount — correctly, because a server that could name one could ask any client to load
## any scene in their build — so naming `res://scenes/room_client.tscn` here means the
## client refuses it, never reports loaded, sits in `LOADING` sending no heartbeats, and
## is timed out for being idle. The symptom is a connection that appears to work and then
## silently does not. [method DotGameDescriptor.client_scene_or_scene] returns the empty
## string for exactly this case, which is the documented "you already have it" path, and
## the application then loads whatever its own build says the client is.
##
## [b]Set — the room is delivered through dot-cloud.[/b] The paths become *relative* and
## resolve under the version-namespaced mount, so a generic client shell that has never
## heard of a room downloads the pack, mounts it, and instantiates the scene named here.
## That is the deployment this game exists for.
static func game_descriptor(manifest_url: String = "") -> DotGameDescriptor:
	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = GAME_ID
	descriptor.display_name = "The Room"
	descriptor.version = "0.1.0"
	descriptor.manifest_url = manifest_url
	descriptor.max_players = RoomContent.MAX_OCCUPANTS
	descriptor.metadata = {"kind": "lobby"}

	if manifest_url == "":
		descriptor.scene = "res://scenes/room_server.tscn"
		descriptor.client_scene = ""
	else:
		descriptor.scene = "scenes/room_server.tscn"
		descriptor.client_scene = "scenes/room_client.tscn"

	return descriptor


# --- Lifecycle -------------------------------------------------------------

func _module_load() -> DotResult:
	world = DotRegistry.get_node_service(RoomWorld.SERVICE) as RoomWorld

	if world == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No RoomWorld is registered.",
			"load the room's scene first, or set DotGameManager.initial_game to '%s'"
				% GAME_ID
		)

	var netted := _build_netcode()

	if not netted.ok:
		return netted

	hook_post("client_spawn", _on_client_spawn)
	server.client_disconnected.connect(_on_client_disconnected)

	# Chat is dot-server's, and the room only listens: a bubble over somebody's head is
	# drawn from what a client was already told, so nothing here relays a message. What
	# this hook is for is the *server's* own view — `room_status` naming who last spoke,
	# and an operator being able to see the room the way a player does.
	hook_post("player_chat", _on_player_chat)

	add_command(
		"room_status", _cmd_status, "Show the room", DotAdminFlags.GENERIC
	)
	add_command("room_who", _cmd_who, "List who is in the room", "")
	add_command(
		"room_net", _cmd_net, "Show the netcode's counters", DotAdminFlags.GENERIC
	)

	if Engine.physics_ticks_per_second != world.tick_rate:
		# Not corrected here: `sv_tickrate` is the operator's and this module is a guest in
		# their server. Loud, because the symptom otherwise is a room that walks at the
		# wrong speed with nothing in the log about it.
		log_warn("sv_tickrate does not match the room's tick rate", {
			"engine": Engine.physics_ticks_per_second,
			"room": world.tick_rate,
		})

	log_info("the room is open", {
		"bounds": world.arena.bounds,
		"capacity": RoomContent.MAX_OCCUPANTS,
	})

	return DotResult.success(null)


func _module_unload() -> void:
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	# Everybody this module put in the room comes out with it. A module that unloaded and
	# left them there would leave the world holding people whose sessions no longer exist,
	# and a netcode manager holding peers nothing will ever drive.
	if bridge != null and is_instance_valid(bridge):
		for userid in _joined.keys():
			bridge.remove_peer(bridge.peer_for_occupant(int(userid)))

	_joined.clear()

	if net != null and is_instance_valid(net):
		net.stop()


func _build_netcode() -> DotResult:
	var config := RoomContent.net_config()
	config.tick_rate = world.tick_rate

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.config = config
	net.config_file = ""
	# The module drives the tick from `server_tick`, in step with dot-server's own, so the
	# manager must not also tick itself from `_physics_process`.
	net.auto_tick = false
	add_child(net)

	var ready := net.setup()

	if not ready.ok:
		return ready.wrap("The netcode could not be set up")

	bridge = RoomBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(world, net, server)

	if not attached.ok:
		return attached.wrap("The bridge could not be attached")

	var started := net.start()

	if not started.ok:
		return started

	return DotResult.success(null)


# --- The tick --------------------------------------------------------------

## One authoritative step of the whole room.
##
## Driven from the module's own [code]_physics_process[/code] rather than from a
## dot-server hook, because dot-server does not have one: it gets a player from "typed an
## address" to "in the world" and hands over, and the simulation rate is the engine's.
## [member DotNetManager.auto_tick] is off for the same reason — two things ticking the
## manager is two ticks a frame.
func _physics_process(_delta: float) -> void:
	# `world == null` is not enough: a game change frees the scene the world lives in
	# before this module is unloaded, and a freed Object is not null. Ticking one is a
	# use-after-free — see [method RoomBridge.live_world].
	if not loaded or bridge == null or not is_instance_valid(bridge) \
			or bridge.live_world() == null:
		return

	_tick += 1
	bridge.server_tick(_tick)


# --- Joining and leaving ---------------------------------------------------

## A client finished joining.
##
## [b]The event carries `userid`, not `peer_id`.[/b] Looking a session up by a key that is
## not in the payload returns null every time, so the handler returns early, every time,
## and nobody is ever put in the room — with no error, because a null session is a
## legitimate thing to find. game-blob and dot-2d-hungry both shipped that line.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	if _joined.has(session.userid):
		return

	# The session id, not the peer id: a peer id is reassigned on reconnect and the next
	# person to join would inherit this one's place in the room.
	var added := bridge.add_occupant(
		session.peer_id, session.userid, session.display_name
	)

	if not added.ok:
		log_warn("could not admit somebody", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	# A client that already asked is admitted now. The two orderings race on a fast
	# loopback: dot-server's signon and this game's READY are separate messages on
	# separate paths, and neither is entitled to arrive first.
	if bridge.peer_is_ready(session.peer_id):
		bridge._admit(session.peer_id, session.userid)


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)


## Somebody said something. dot-server has already routed and sanitised it.
func _on_player_chat(event: DotEvent) -> void:
	var userid := event.get_int("userid")
	var occupant := world.occupant_for(userid) if world != null else null

	if occupant == null:
		return

	occupant.say(event.get_string("text"), Time.get_ticks_msec())


# --- Commands --------------------------------------------------------------

func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(world.describe_lines())


func _cmd_who(ctx: DotCmdContext) -> void:
	var now := int(Time.get_unix_time_from_system())

	ctx.reply("%-6s %-22s %-9s %s" % ["id", "name", "here for", "at"])

	for occupant in world.roster():
		ctx.reply("%-6d %-22s %6ds   %6.0f,%6.0f" % [
			occupant.id,
			occupant.display_name,
			maxi(0, now - occupant.joined_at),
			occupant.position().x,
			occupant.position().y,
		])


func _cmd_net(ctx: DotCmdContext) -> void:
	ctx.reply_lines(bridge.describe_lines())

	if net != null:
		ctx.reply_lines(net.describe_lines())
