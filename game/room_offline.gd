class_name RoomOffline
extends Node

## A server and a client in one tree, with a loopback between them.
##
## What `--offline` is, and what `examples/headless_net.tscn` drives. There is no socket,
## no [DotServer] and no signon: two [RoomBridge]s, two [DotNetManager]s and two
## [RoomWorld]s, with each end's [member RoomLink.loopback] pointed at the other's
## [method RoomLink.deliver].
##
## [b]Every byte still goes through the real encoders.[/b] The loopback replaces the
## socket and nothing else — the same snapshots, the same events, the same acknowledgement
## header, the same prediction and the same reconciliation. What it buys is a run that
## reproduces exactly, twice, which a real socket cannot: latency, reordering and loss are
## different every time, and a netcode check that cannot be repeated is a netcode check
## that cannot be trusted when it fails.
##
## It also, deliberately, buys a way to look at the room with nobody else in it. A scene
## that can only be run by connecting to something is a scene nobody ever runs.

const CHANNEL := "room.offline"

## Peer id the local client is given. Anything but 1, which is the server's.
const CLIENT_PEER := 2

## Session id the local person gets. Well clear of anything a real server hands out,
## which counts up from 1 — so a transcript from an offline run is never mistaken for one
## from a real session.
const CLIENT_OCCUPANT := 500001

var server_world: RoomWorld = null
var server_net: DotNetManager = null
var server_bridge: RoomBridge = null

var client_world: RoomWorld = null
var client_net: DotNetManager = null
var client_bridge: RoomBridge = null

## Ticks each direction is delayed, for a run that wants to see prediction work.
##
## [b]Ticks, not milliseconds.[/b] A wall-clock delay measured against a loop that
## advances a tick per *frame* is not a delay at all: a headless run does several hundred
## frames a second, so a "60 ms" latency swallows every packet for the first fifty ticks
## and the client predicts into a void. The first version of this file did that, and the
## symptom was 240 units of drift under packet loss — which reads as a broken predictor
## and is a broken clock. Ticks are also what makes the loopback reproducible, which is
## its entire reason for existing.
##
## Zero by default: an offline lobby should feel like a local game, and a person looking
## at the room to check it draws correctly does not want a simulated round trip.
var latency_ticks: int = 0

## Fraction of snapshots dropped, for the same reason. Zero by default.
##
## Only snapshots: dropping a reliable event would be dropping something the transport
## promises to redeliver and this loopback does not implement retransmission. A test that
## wants to see a lost join is testing dot-net's reliability layer, not this.
var loss: float = 0.0

var _server_link_host: Node = null
var _client_link_host: Node = null
var _pending: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

## The newest tick [method server_tick] was given. What a delay is measured in.
var _tick: int = 0


## Builds both ends and puts one person in the room.
func start(display_name: String, seed_value: int = 20260829) -> DotResult:
	_rng.seed = seed_value

	# The link's parent is what the RPC path is made of on a real connection — [DotServer]
	# on one side, [DotClientLink] on the other, both named `Server`. Here nothing is
	# routed by path, and the names are kept anyway: a loopback whose tree differed from
	# the real one would be a loopback that could not reproduce a routing bug.
	_server_link_host = Node.new()
	_server_link_host.name = "Server"
	add_child(_server_link_host)

	_client_link_host = Node.new()
	_client_link_host.name = "Server"
	add_child(_client_link_host)

	var built := _build_server()

	if not built.ok:
		return built

	var joined := _build_client()

	if not joined.ok:
		return joined

	var added := server_bridge.add_occupant(CLIENT_PEER, CLIENT_OCCUPANT, display_name)

	if not added.ok:
		return added

	return DotResult.success(self)


func _build_server() -> DotResult:
	server_world = _world(true, &"offline_server")

	var config := RoomContent.net_config()

	server_net = DotNetManager.new()
	server_net.name = "ServerNet"
	server_net.is_server = true
	server_net.local_peer_id = 1
	server_net.config = config
	server_net.config_file = ""
	server_net.auto_tick = false
	add_child(server_net)

	var ready := server_net.setup()

	if not ready.ok:
		return ready

	server_bridge = RoomBridge.new()
	server_bridge.name = "ServerBridge"
	add_child(server_bridge)

	var attached := server_bridge.attach(server_world, server_net, _server_link_host)

	if not attached.ok:
		return attached

	server_bridge.link.loopback = func(
		method: StringName, peer_id: int, payload: PackedByteArray
	) -> void:
		_queue(false, method, peer_id, payload)

	return server_net.start()


func _build_client() -> DotResult:
	client_world = _world(false, &"offline_client")

	var config := RoomContent.net_config()

	client_net = DotNetManager.new()
	client_net.name = "ClientNet"
	client_net.is_server = false
	client_net.local_peer_id = CLIENT_PEER
	client_net.config = config
	client_net.config_file = ""
	client_net.auto_tick = false
	add_child(client_net)

	var ready := client_net.setup()

	if not ready.ok:
		return ready

	client_bridge = RoomBridge.new()
	client_bridge.name = "ClientBridge"
	add_child(client_bridge)

	var attached := client_bridge.attach(client_world, client_net, _client_link_host)

	if not attached.ok:
		return attached

	# The loopback knows exactly what it is delaying, so it says so rather than leaving
	# the clock to assume a perfect link. This is the same wiring a real client does from
	# [method DotClientLink.ping_ms]; only the source differs.
	client_bridge.rtt_source = func() -> float:
		return float(latency_ticks) * 2.0 * client_net.clock.tick_duration() * 1000.0

	client_bridge.link.loopback = func(
		method: StringName, _peer_id: int, payload: PackedByteArray
	) -> void:
		_queue(true, method, CLIENT_PEER, payload)

	return client_net.start()


func _world(authority: bool, scope: StringName) -> RoomWorld:
	var made := RoomWorld.new()
	made.name = "AuthorityWorld" if authority else "MirrorWorld"
	made.is_authority = authority
	made.tick_rate = RoomContent.TICK_RATE
	# Not published. Two worlds in one process under one name means one of them is
	# invisible and a module binds to whichever registered last — and here there are two
	# by construction.
	made.register_service = false
	made.service_scope = scope
	add_child(made)
	made.setup()
	return made


# --- The wire --------------------------------------------------------------

## Queues one payload for the other end.
func _queue(
	to_server: bool,
	method: StringName,
	peer_id: int,
	payload: PackedByteArray
) -> void:
	if method == &"snapshot" and loss > 0.0 and _rng.randf() < loss:
		return

	_pending.append({
		"to_server": to_server,
		"method": method,
		"peer": peer_id,
		"payload": payload,
		"at": _tick + latency_ticks,
	})


## Delivers whatever is due. Called from [method server_tick].
func _flush() -> void:
	if _pending.is_empty():
		return

	var keep: Array[Dictionary] = []

	for entry in _pending:
		if int(entry["at"]) > _tick:
			keep.append(entry)
			continue

		var link: RoomLink = (
			server_bridge.link if bool(entry["to_server"]) else client_bridge.link
		)

		if link != null and is_instance_valid(link):
			link.deliver(entry["method"], int(entry["peer"]), entry["payload"])

	_pending = keep


## One authoritative tick, and one delivery pass.
##
## The client's own tick is driven by whoever owns this — [RoomClient] from its
## `_physics_process`, or a test from a loop — because the client half is the thing under
## test and a helper that ticked both would hide the ordering.
func server_tick(tick: int) -> void:
	_tick = tick

	if server_bridge != null:
		server_bridge.server_tick(tick)

	_flush()


## Puts a chat line into the offline room, the way dot-server would.
##
## Offline there is no [DotChatManager] to route it, so this is the one place the shape of
## a chat payload is restated. It is restated as *dot-server's* shape rather than as a
## convenient one, so [method RoomClient._on_chat] takes the same dictionary either way.
func say(text: String, from: int = CLIENT_OCCUPANT) -> Dictionary:
	var occupant := client_world.occupant_for(from)

	# The bubble is not set here. [RoomClient] sets it from the payload, the same way it
	# does for a line that arrived from a real server — one path, so an offline bubble can
	# never behave differently from an online one.
	return {
		"kind": "all",
		"userid": from,
		"name": occupant.display_name if occupant != null else "Guest",
		"text": text,
		"admin": false,
	}


func describe() -> Dictionary:
	return {
		"pending": _pending.size(),
		"latency_ticks": latency_ticks,
		"loss": loss,
		"server": server_bridge.describe() if server_bridge != null else {},
		"client": client_bridge.describe() if client_bridge != null else {},
	}
