class_name RoomBridge
extends Node

## Joins a [RoomWorld] to a [DotNetManager], on both ends.
##
## The same script runs on the server and on a client and branches on
## [member DotNetManager.is_server] — because every one of these decisions is a pair, and
## a pair split across two files drifts. dot-2d-hungry's bridge is the same shape and this
## is a much smaller version of it: a lobby has no eating, no rounds, no projectiles and
## no field, so what is left is membership, one entity per person, and the tick.
##
## [b]The manager outlives the world.[/b] A game change frees the scene the world lives in
## and instantiates the next one; rebuilding the manager with it would reset the message
## ids, the peer records and the clock — a disconnect for everybody, which is precisely
## what changing the game is supposed to avoid. So the manager and this bridge belong to
## the module, and [method rebind] moves the bridge onto the new world.

const CHANNEL := "room.net"

## Bytes of acknowledgement in front of every input packet. Fixed width, so a reader can
## skip it without decoding the bit-packed command behind it.
const ACK_BYTES := 4

## Somebody arrived, left, or was renamed. The roster and the feed are drawn from this.
signal roster_changed(occupant_id: int, present: bool)

## The hello landed and this client knows who it is. Client side.
signal hello_received(occupant_id: int)

## The server has finished sending the roster. Client side, and what "you are in" means.
signal roster_complete()

var world: RoomWorld = null
var net: DotNetManager = null
var link: RoomLink = null

## Which occupant this client is. Zero on the server and before the hello.
var local_occupant_id: int = 0

## Where the round-trip time comes from. Client side; returns milliseconds.
##
## [b]Not optional, and nothing in dot-net supplies it.[/b] [DotNetClock] estimates which
## tick the server is on as `received tick + half the round trip`, and puts the input
## timeline [member DotNetConfig.input_margin_ticks] ahead of *that*. Fed nothing, it
## assumes a zero-latency link — so on any connection with more than about 30 ms of
## one-way delay the client stamps every command for a tick the server has already
## simulated, the server discards every one as late, and the player moves on their own
## screen and nowhere else. There is no error on either end.
##
## dot-net cannot measure this itself: it never touches a transport. dot-server already
## does, through its heartbeat, which is what [RoomClient] points this at.
var rtt_source: Callable = Callable()

## Where the replicated nodes live. A plain container, so nothing walks the whole tree.
var _entities: Node = null

## peer id -> session id, and back.
var _occupant_of_peer: Dictionary = {}
var _peer_of_occupant: Dictionary = {}

## Peers that have said they can receive.
##
## [b]Nothing may be sent to a peer before it says so.[/b] dot-server's signon finishes
## and *then* the client builds its scene; everything sent in between lands on a node that
## does not exist and is lost, one "Node not found" per call. [constant RoomEvents.Ask.READY]
## is the client saying it has somewhere to put them.
var _ready_peers: Dictionary = {}

## occupant id -> [RoomOccupantNet].
var _behaviours: Dictionary = {}

## net id -> occupant id, for a client applying a despawn.
var _occupant_of_net: Dictionary = {}

## occupant id -> the newest [Dot2DCommand] for this tick.
var _commands: Dictionary = {}

## The newest tick [method server_tick] was given. The server's authoritative clock.
##
## [b]Not [code]net.clock.tick[/code].[/b] The manager's clock only advances when the
## manager ticks itself, and this one does not — the module drives it in step with the
## engine's physics tick so that the world and the netcode cannot drift apart. So this is
## the number, and it is what the hello carries: a client anchored to a clock that never
## left zero stamps every input for a tick the server passed long ago, the server discards
## every one of them as late, nothing errors, and the player simply cannot move while
## moving perfectly on their own screen.
var _tick: int = 0

var _room_ticked_for: int = -1
var _client_ticked_for: int = -1


# --- Wiring ----------------------------------------------------------------

## Binds a world and a manager to each other and puts the link where RPCs will find it.
##
## [param link_parent] is [DotServer] on a server and [DotClientLink] on a client, and both
## of them are named [code]Server[/code] — see [RoomLink] for why that is the whole of the
## routing.
func attach(p_world: RoomWorld, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_world == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_world.is_authority != p_net.is_server:
		# A world that thinks it is authoritative behind a client manager would place
		# people itself; a server whose world is not authoritative would place nobody.
		# Both are silent, and both are a room where nobody can move.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world.is_authority=%s, net.is_server=%s"
				% [p_world.is_authority, p_net.is_server]
		)

	world = p_world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	# The default distance strategy, with `always_relevant` on every occupant — see
	# [method _build_occupant_entity]. A lobby needs no interest management and shipping a
	# strategy that did nothing would be a class to keep in step for no benefit.
	net.send_fn = _send

	var registered := _register_messages()

	if not registered.ok:
		return registered

	if net.is_server:
		world.occupant_joined.connect(_on_occupant_joined)
		world.occupant_left.connect(_on_occupant_left)

	link = RoomLink.attached_to(link_parent, self, net.is_server)
	return DotResult.success(self)


## Moves this bridge onto a new world, keeping every connection. Server side.
##
## What a game change is from the netcode's point of view: the world is a scene
## [DotGameManager] frees and replaces; the manager, its peers, its message ids and its
## clock are not. So every replicated occupant is despawned, the new world is populated
## with the same people, and everyone is resynchronised.
func rebind(new_world: RoomWorld) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server rebinds.")

	if new_world == null or not new_world.is_authority:
		return DotResult.fail(
			DotError.CODE_INVALID, "A bridge rebinds onto an authoritative world."
		)

	# Who is here, before the old world goes. The peer map survives a game change; the
	# occupants do not, and their names are the only thing in them worth carrying across.
	var carried: Array[Dictionary] = []

	for peer_key in _occupant_of_peer.keys():
		var occupant_id := int(_occupant_of_peer[peer_key])
		var occupant := world.occupant_for(occupant_id) if world != null else null

		carried.append({
			"peer": int(peer_key),
			"occupant": occupant_id,
			"name": occupant.display_name if occupant != null else "Player %d" % occupant_id,
		})

	for occupant_id in _behaviours.keys():
		_release_entity(int(occupant_id), true)

	_behaviours.clear()
	_commands.clear()

	if world != null:
		world.occupant_joined.disconnect(_on_occupant_joined)
		world.occupant_left.disconnect(_on_occupant_left)

	world = new_world
	world.occupant_joined.connect(_on_occupant_joined)
	world.occupant_left.connect(_on_occupant_left)

	for row in carried:
		var added := world.add_occupant(int(row["occupant"]), String(row["name"]))

		if not added.ok:
			continue

		var peer_id := int(row["peer"])

		if _ready_peers.has(peer_id):
			_send_hello(peer_id, int(row["occupant"]))
			_send_roster(peer_id)

	_room_ticked_for = -1
	return DotResult.success(world)


func _register_messages() -> DotResult:
	var event := net.messages.register(
		RoomEvent.NAME,
		RoomEvent,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		RoomRequest.NAME,
		RoomRequest,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(RoomEvent.NAME, _on_event)
	net.messages.on(RoomRequest.NAME, _on_request)
	return DotResult.success(true)


# --- Transport -------------------------------------------------------------

## Where every byte leaves through.
##
## Snapshots and messages both come out here, and the only thing that distinguishes them
## is the delivery: dot-net sends state unreliably and nothing else, and every message
## this game defines is reliable. Routing on that is exact rather than a heuristic, and it
## is why neither message type may ever be declared unreliable.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## Sends an event to everybody who can receive one.
##
## Peer by peer rather than [method DotNetManager.send]'s broadcast, because a broadcast
## goes to every connected peer including the ones that have not built their scene yet —
## and every one of those is a "Node not found" in the log and an event nobody got.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server:
		return

	for peer_id in _ready_peers.keys():
		net.send(RoomEvent.of(kind, body), int(peer_id))


## Sends an event to one peer.
##
## [b]A peer id of zero means "nobody", not "everybody".[/b] Anything in this room without
## a connection carries peer 0, and falling through to the manager's broadcast would send
## one person's private hello to every client. dot-2d-hungry shipped that bug; broadcasting
## is [method _broadcast]'s job and it says so.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or peer_id <= 0:
		return

	net.send(RoomEvent.of(kind, body), peer_id)


# --- Membership ------------------------------------------------------------

## Puts somebody in the room and makes them a replicated entity. Server side.
##
## [param occupant_id] is the session id everything downstream uses — the roster key, the
## colour seed, the chat bubble's owner. [b]It is not the peer id.[/b] A peer id is
## reassigned the moment somebody reconnects, and everything keyed by one would be handed
## to the next person to join.
func add_occupant(
	peer_id: int,
	occupant_id: int,
	display_name: String
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server admits people.")

	# [b]The peer map is written before the world is told, not after.[/b]
	# [method RoomWorld.add_occupant] emits `occupant_joined` synchronously, and
	# [method _on_occupant_joined] builds the [DotNetIdentity] from
	# [method peer_for_occupant] — so writing the map afterwards gives every entity
	# `owner_peer_id = 0`. Nothing errors: the entity replicates perfectly, it is simply
	# owned by nobody, so [method DotNetManager._apply_input] hands the peer's commands to
	# an empty list and the person never moves on the server while moving perfectly on
	# their own screen. It reads as a broken predictor and is a broken assignment.
	if peer_id > 0:
		_occupant_of_peer[peer_id] = occupant_id
		_peer_of_occupant[occupant_id] = peer_id

	var added := world.add_occupant(occupant_id, display_name)

	if not added.ok:
		if peer_id > 0:
			_occupant_of_peer.erase(peer_id)
			_peer_of_occupant.erase(occupant_id)

		return added

	return added


## Takes a peer out of the room and off the manager.
func remove_peer(peer_id: int) -> void:
	if net == null or not net.is_server or peer_id <= 0:
		return

	var occupant_id := int(_occupant_of_peer.get(peer_id, 0))

	# Off the broadcast set *before* the world is told, not after. Removing the occupant
	# fires `occupant_left` synchronously, which broadcasts a LEAVE to every ready peer —
	# and this one has gone, so the RPC is addressed to a peer the transport no longer
	# knows and Godot answers with "Attempt to call RPC with unknown peer ID". Harmless,
	# and it appears in the log of every disconnect, which is where somebody looks when
	# something else is wrong.
	_ready_peers.erase(peer_id)
	_occupant_of_peer.erase(peer_id)

	if occupant_id != 0:
		# [b]Guarded, because the world may already be freed.[/b] This runs on the way out
		# of a game as well as on a disconnect: [DotGameManager] frees the old scene, and
		# only afterwards does the module that owned it get unloaded — and unloading is
		# what takes everybody out. So on a game change this reached a freed [RoomWorld],
		# which is not null and is a use-after-free, and it killed the process.
		#
		# The rest still has to happen. The peer's entities, its input buffer and its
		# acknowledgement record belong to the netcode, which outlives the scene; returning
		# early here would leak all three into the next game.
		var live := live_world()

		if live != null:
			live.remove_occupant(occupant_id)

		_peer_of_occupant.erase(occupant_id)

	# The entity is the netcode's, not the world's, so it goes whether or not the world
	# is still there. Without this a changed game inherits the previous one's entities.
	_release_entity(occupant_id, false)
	_behaviours.erase(occupant_id)
	_commands.erase(occupant_id)

	if net.peers().has(peer_id):
		net.remove_peer(peer_id)


func occupant_for_peer(peer_id: int) -> RoomOccupant:
	var occupant_id := int(_occupant_of_peer.get(peer_id, 0))
	return world.occupant_for(occupant_id) if occupant_id != 0 else null


func peer_for_occupant(occupant_id: int) -> int:
	return int(_peer_of_occupant.get(occupant_id, 0))


func local_occupant() -> RoomOccupant:
	return world.occupant_for(local_occupant_id) if world != null else null


func ready_peer_count() -> int:
	return _ready_peers.size()


## Marks a peer able to receive, and gives it everything it has missed.
##
## Also where the peer joins the manager: a peer registered before it can receive is a
## peer the server builds and sends a snapshot to every tick, into a node that does not
## exist yet.
func _admit(peer_id: int, occupant_id: int) -> void:
	if peer_id <= 0:
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	_send_hello(peer_id, occupant_id)
	_send_roster(peer_id)


# --- Replicated occupants --------------------------------------------------

func _on_occupant_joined(occupant: RoomOccupant) -> void:
	if net == null or not net.is_server:
		return

	var peer_id := peer_for_occupant(occupant.id)
	var identity := _build_occupant_entity(occupant, peer_id)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.error(CHANNEL, "could not register an occupant", {
			"occupant": occupant.id, "error": str(registered.error)
		})
		return

	_occupant_of_net[identity.net_id] = occupant.id

	# The two events are separate and both are needed. JOIN is who they are — the name and
	# the moment, which the roster and the feed are drawn from. SPAWN is which net id
	# carries their position. A client that only had the second would have somebody
	# walking around with no name; one that only had the first would have a name attached
	# to nothing.
	_broadcast(
		RoomEvents.Kind.JOIN,
		RoomEvents.write_join(
			occupant.id, occupant.display_name, occupant.position(), occupant.joined_at
		)
	)
	_broadcast(
		RoomEvents.Kind.SPAWN,
		RoomEvents.write_spawn(
			identity.net_id, peer_id, occupant.id, occupant.position()
		)
	)

	roster_changed.emit(occupant.id, true)


func _on_occupant_left(occupant: RoomOccupant) -> void:
	if net == null or not net.is_server:
		return

	var net_id := _release_entity(occupant.id, true)
	_behaviours.erase(occupant.id)
	_occupant_of_net.erase(net_id)
	_commands.erase(occupant.id)

	_broadcast(RoomEvents.Kind.LEAVE, RoomEvents.write_occupant(occupant.id))
	roster_changed.emit(occupant.id, false)


## Builds the node, behaviour and identity that make an occupant replicate.
func _build_occupant_entity(occupant: RoomOccupant, peer_id: int) -> DotNetIdentity:
	var root := Node2D.new()
	root.name = "Occupant%d" % occupant.id
	root.position = occupant.position()
	_entities.add_child(root)

	var behaviour := RoomOccupantNet.new()
	behaviour.name = "Net"
	behaviour.occupant = occupant
	behaviour.bridge = self
	root.add_child(behaviour)

	# After the behaviour: [DotNetIdentity] collects behaviours in `_ready` by walking the
	# entity's subtree, and one added afterwards would never be found — the entity would
	# register with nothing to replicate and simply never update on any other machine.
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED, not SERVER: the server stays authoritative and corrects, and the owning
	# client predicts. [method DotNetIdentity.is_predicted] is false for any other
	# authority, so SERVER would mean walking a full round trip behind your own keyboard.
	identity.authority = DotNetIdentity.Authority.SHARED
	# [b]Everybody in a lobby is relevant to everybody else.[/b] The room is smaller than
	# a screen and the roster names every person in it anyway, so hiding somebody's
	# position would save 13 bytes a snapshot and produce a name in the list with nobody
	# under it. The cap that makes this affordable is
	# [constant RoomContent.MAX_OCCUPANTS]; past that a room needs interest management and
	# stops being a lobby.
	identity.always_relevant = true
	identity.interest_tags = PackedStringArray(["occupant"])
	root.add_child(identity)

	occupant.net = behaviour
	_behaviours[occupant.id] = behaviour

	return identity


## Frees an occupant's entity and, on the server, tells everybody. Returns its net id.
func _release_entity(occupant_id: int, announce: bool) -> int:
	var behaviour := _behaviours.get(occupant_id) as RoomOccupantNet

	if behaviour == null or behaviour.identity == null:
		return 0

	var net_id := behaviour.identity.net_id
	var root := behaviour.identity.get_parent()

	if net != null and net.registry != null:
		net.registry.unregister(net_id)

	if announce and net != null and net.is_server:
		_broadcast(RoomEvents.Kind.DESPAWN, RoomEvents.write_despawn(net_id))

	if root != null and is_instance_valid(root):
		root.get_parent().remove_child(root)
		root.queue_free()

	return net_id


func behaviour_for(occupant_id: int) -> RoomOccupantNet:
	return _behaviours.get(occupant_id)


func entity_count() -> int:
	return _behaviours.size()


## The world, or null when there is not one any more.
##
## [b]`world == null` is not the check, and this is the difference that segfaults a
## server.[/b] A game change frees the scene the world lives in, and a freed [Object] is
## NOT null — it is a reference whose next method call is a use-after-free. GDScript
## sometimes catches it ("Nonexistent function ... in base 'previously freed'") and
## sometimes does not; under a live client, changing the game took the second path and
## killed the process.
##
## The window is real and unavoidable: [DotGameManager] frees the old scene and loads the
## new one, and only afterwards does anything hear `game_loaded` and unload the module
## that owned the old world. In between, this module's own `_physics_process` is still
## ticking — so every read of the world on the tick path has to expect it to be gone.
func live_world() -> RoomWorld:
	return world if world != null and is_instance_valid(world) else null


# --- The authoritative tick ------------------------------------------------

## One authoritative tick. Server side, and it replaces [method RoomWorld.tick].
##
## [method DotNetManager.server_tick] hands each peer's input to the entities it owns,
## simulates every behaviour, records history and sends snapshots — in that order, and the
## room tick has to happen between the first two. It does, from
## [method RoomOccupantNet._net_simulate] through [method ensure_room_ticked].
##
## The call afterwards is not redundant: it is what ticks an *empty* room, which has no
## entities and therefore no behaviour to drive one. It costs one integer comparison when
## the room has already run.
func server_tick(tick: int) -> void:
	_tick = tick
	_room_ticked_for = -1

	if net != null:
		net.server_tick(tick)

	ensure_room_ticked(tick)


## Runs the whole room for a tick, at most once.
func ensure_room_ticked(tick: int) -> void:
	var live := live_world()

	if _room_ticked_for == tick or live == null:
		return

	_room_ticked_for = tick
	live.tick(_commands)


## Takes one tick of a person's intent, on its way from an input packet to the world.
##
## Written to the occupant as well as to the tick's command table, because the two ends
## read different ones and both have to see it. The server ticks the whole room from
## [member _commands]; a reconciling client replays one occupant at a time through
## [method predict_occupant], which reads [member RoomOccupant.last_command] — and
## [method DotNetPredictor.reconcile] puts each replayed tick's own input back through
## [method RoomOccupantNet._net_apply_input], which lands here. Writing only the table
## would make every replay run on whatever command the occupant happened to be holding,
## which is the newest one rather than the one the server simulated for that tick.
##
## Silent whenever somebody walks in one direction for the whole unacknowledged window —
## which is most of a test and none of a lobby, where people change direction constantly.
func note_command(occupant_id: int, command: Dot2DCommand) -> void:
	if command == null:
		return

	_commands[occupant_id] = command

	var occupant := world.occupant_for(occupant_id) if world != null else null

	if occupant != null:
		occupant.last_command = command


# --- The client tick -------------------------------------------------------

## One client tick: record the local command, send it, predict.
##
## The command is recorded into the manager's input history [i]before[/i] predicting,
## because reconciliation replays that history — an input the buffer never saw is a tick
## the replay cannot reproduce, and the correction is then measured against a state the
## server never computed.
func client_tick(tick: int, command: Dot2DCommand) -> void:
	if net == null or net.is_server or live_world() == null:
		return

	_tick = tick

	if _client_ticked_for != tick:
		_client_ticked_for = tick
		world.client_tick(tick)

	var me := local_occupant()

	if me != null and command != null:
		me.last_command = command.duplicate_command()

	var packet := RoomNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.command = command if command != null else Dot2DCommand.new()

	net.local_inputs().push(packet)

	if link != null:
		# The acknowledgement goes in front because it is fixed width. A bit-packed
		# command is not, so a reader that had to skip it would have to decode it first.
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		packet.write(writer)
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	for identity in net.registry.predicted():
		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, net.clock.tick_duration())


## Advances one predicted occupant. Called from [method RoomOccupantNet._net_simulate].
func predict_occupant(occupant: RoomOccupant, tick: int, delta: float) -> void:
	var live := live_world()

	if live == null or occupant == null:
		return

	live.simulate_occupant(occupant, occupant.last_command, delta, tick)


# --- Receiving -------------------------------------------------------------

func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "A server does not take snapshots.")

	# Before the snapshot, not after: [method DotNetManager.receive_snapshot] reads the
	# measured round trip out of `stats` to work out which tick the server is on, and a
	# sample noted afterwards is a sample that arrives one snapshot too late to be used.
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	# [b]This must not reconcile.[/b] [method DotNetManager.receive_snapshot] already
	# routes a predicted entity's state to the predictor and acknowledges the inputs it
	# covers; a second pass replays the same inputs against values that were already
	# rewound. game-arena's bridge did that and read a correction rate of 0.500 against
	# 0.032 without it.
	return net.receive_snapshot(payload)


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server or peer_id <= 0:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a server takes inputs.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "An input packet is too short.")

	if not _occupant_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has nobody in the room.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	var command := RoomNetCommand.new()
	command.read(DotNetReader.new(payload.slice(ACK_BYTES)))

	# Sanitised by [method DotNetManager._apply_input] on the way out of the buffer, not
	# here. One place, on the path every input takes, rather than one per caller — and the
	# one a caller forgot would be the one a cheat used.
	return net.input_buffer_for(peer_id).push(command)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "A server does not take events.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server or peer_id <= 0:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a server takes requests.")

	return net.receive(payload, peer_id)


# --- Events, outbound ------------------------------------------------------

func _send_hello(peer_id: int, occupant_id: int) -> void:
	_tell(
		peer_id,
		RoomEvents.Kind.HELLO,
		RoomEvents.write_hello(
			occupant_id,
			peer_id,
			_tick,
			world.tick_rate,
			world.arena.bounds.size
		)
	)


## Everybody already here, then the marker that says the list is complete.
##
## The occupant this peer *is* goes out with everybody else rather than being skipped: a
## client that had to synthesise its own row would have a row nothing else produced, and
## the first thing to diverge would be its own name.
func _send_roster(peer_id: int) -> void:
	for occupant in world.roster():
		_tell(
			peer_id,
			RoomEvents.Kind.JOIN,
			RoomEvents.write_join(
				occupant.id,
				occupant.display_name,
				occupant.position(),
				occupant.joined_at
			)
		)

		var behaviour := behaviour_for(occupant.id)

		if behaviour != null and behaviour.identity != null:
			_tell(
				peer_id,
				RoomEvents.Kind.SPAWN,
				RoomEvents.write_spawn(
					behaviour.identity.net_id,
					peer_for_occupant(occupant.id),
					occupant.id,
					occupant.position()
				)
			)

	_tell(peer_id, RoomEvents.Kind.ROSTER_END, RoomEvents.write_empty())


# --- Events, inbound -------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as RoomEvent

	if event == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		RoomEvents.Kind.HELLO:
			_apply_hello(reader)
		RoomEvents.Kind.JOIN:
			_apply_join(reader)
		RoomEvents.Kind.LEAVE:
			_apply_leave(reader)
		RoomEvents.Kind.SPAWN:
			_apply_spawn(reader)
		RoomEvents.Kind.DESPAWN:
			_apply_despawn(reader)
		RoomEvents.Kind.ROSTER_END:
			roster_complete.emit()
		_:
			DotLog.warn(CHANNEL, "unhandled event", {"kind": event.kind})


func _apply_hello(reader: DotNetReader) -> void:
	var hello := RoomEvents.read_hello(reader)

	if not bool(hello["ok"]):
		DotLog.error(CHANNEL, "a malformed hello")
		return

	var size: Vector2 = hello["room_size"]

	if not size.is_equal_approx(world.arena.bounds.size):
		# Refused loudly rather than adopted. Every position would still decode and every
		# id would still match; people would simply be standing somewhere else, which is
		# the most confusing failure this protocol has and the only one worth a check.
		DotLog.error(CHANNEL, "the server's room is a different size", {
			"server": size, "client": world.arena.bounds.size,
		})
		return

	local_occupant_id = int(hello["occupant_id"])
	net.local_peer_id = int(hello["peer_id"])

	# The round trip goes in with the very first anchor, not from the first snapshot a
	# fifteenth of a second later. The clock puts the input timeline ahead of the server by
	# the flight time plus a margin; anchored with a zero it puts it ahead by the margin
	# alone, and until the estimate catches up every command is discarded as late.
	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["tick"]), maxf(0.0, rtt))
	hello_received.emit(local_occupant_id)


func _apply_join(reader: DotNetReader) -> void:
	var join := RoomEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var occupant_id := int(join["occupant_id"])
	var occupant := world.occupant_for(occupant_id)

	if occupant == null:
		var added := world.add_occupant(occupant_id, String(join["name"]))

		if not added.ok:
			return

		occupant = added.value

	# A JOIN for somebody already here is the roster resend after a game change, not a
	# duplicate. The name and the moment are refreshed; the position is not, because a
	# snapshot has almost certainly moved them since and this body carries where they
	# *entered*.
	occupant.display_name = String(join["name"])
	occupant.joined_at = int(join["joined_at"])
	occupant.is_local = occupant_id == local_occupant_id

	if occupant.net == null:
		occupant.state.position = join["position"]

	roster_changed.emit(occupant_id, true)


func _apply_leave(reader: DotNetReader) -> void:
	var occupant_id := RoomEvents.read_occupant(reader)

	if occupant_id == 0:
		return

	_release_entity(occupant_id, false)
	_behaviours.erase(occupant_id)
	world.remove_occupant(occupant_id)
	roster_changed.emit(occupant_id, false)


func _apply_spawn(reader: DotNetReader) -> void:
	var spawn := RoomEvents.read_spawn(reader)

	if not bool(spawn["ok"]):
		return

	var occupant_id := int(spawn["occupant_id"])

	if _behaviours.has(occupant_id):
		return

	var occupant := world.occupant_for(occupant_id)

	if occupant == null:
		# A spawn before its join. Legal: the two are separate reliable messages and only
		# their order within one stream is guaranteed, which a game change can break.
		# A placeholder name is replaced by the JOIN when it lands.
		var added := world.add_occupant(occupant_id, "Player %d" % occupant_id)

		if not added.ok:
			return

		occupant = added.value

	occupant.state.position = spawn["position"]
	occupant.is_local = occupant_id == local_occupant_id

	var identity := _build_occupant_entity(occupant, int(spawn["peer_id"]))
	var registered := net.registry.register(
		identity, int(spawn["net_id"]), net.clock.tick, net.config
	)

	if not registered.ok:
		DotLog.error(CHANNEL, "could not mirror an occupant", {
			"occupant": occupant_id, "error": str(registered.error)
		})
		return

	_occupant_of_net[int(spawn["net_id"])] = occupant_id


func _apply_despawn(reader: DotNetReader) -> void:
	var net_id := RoomEvents.read_despawn(reader)
	var occupant_id := int(_occupant_of_net.get(net_id, 0))

	if occupant_id == 0:
		return

	_release_entity(occupant_id, false)
	_behaviours.erase(occupant_id)
	_occupant_of_net.erase(net_id)


# --- Requests --------------------------------------------------------------

## Client side: tell the server there is somewhere to put events.
func ask_for_room() -> void:
	if net == null or net.is_server:
		return

	net.send(RoomRequest.of(RoomEvents.Ask.READY), 1)


func _on_request(message: DotNetMessage) -> void:
	var request := message as RoomRequest

	if request == null or net == null or not net.is_server:
		return

	var peer_id := request.sender_peer_id

	match request.kind:
		RoomEvents.Ask.READY:
			var occupant_id := int(_occupant_of_peer.get(peer_id, 0))

			if occupant_id == 0:
				# A peer asking before the module has admitted it. Not an error and not
				# ignorable: the module admits on `client_spawn`, and the two orderings
				# race on a fast loopback. The peer is remembered as ready and
				# [method add_occupant]'s caller admits it when it arrives.
				_ready_peers[peer_id] = true
				return

			_admit(peer_id, occupant_id)
		_:
			DotLog.warn(CHANNEL, "unhandled request", {"kind": request.kind})


## The tick the authority is on. Server side.
func server_tick_number() -> int:
	return _tick


## Whether a peer has already said it can receive. Server side.
func peer_is_ready(peer_id: int) -> bool:
	return _ready_peers.has(peer_id)


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"role": "server" if net != null and net.is_server else "client",
		"occupants": world.occupant_count() if world != null else 0,
		"entities": _behaviours.size(),
		"peers": _occupant_of_peer.size(),
		"ready": _ready_peers.size(),
		"local": local_occupant_id,
		# The link's PATH, not just its counters. Godot routes an RPC by the receiver's
		# node path relative to its MultiplayerAPI root, so when nothing arrives the
		# first question is what the two ends think that path is — and a describe that
		# only counts messages cannot answer it.
		"link_path": str(link.get_path()) if link != null and link.is_inside_tree() else "-",
		"link": link.describe() if link != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var info := describe()

	for key in info.keys():
		out.append("%-10s %s" % [key, info[key]])

	return out
