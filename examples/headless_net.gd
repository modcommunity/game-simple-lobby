extends Node

## The netcode, over a lossy loopback: encoders, membership, prediction, interpolation.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## godot --headless --path . res://examples/headless_net.tscn -- --verbose
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]A loopback rather than a socket, deliberately.[/b] A real socket does not reproduce
## the same latency, reordering and loss twice, and a netcode check that cannot be
## repeated cannot be trusted when it fails. Every byte still goes through the real
## encoders, the real acknowledgement header, the real prediction and the real
## reconciliation — the socket is the only thing replaced. `examples/sandbox.tscn` is where
## a real one is used, and it is checking something else: the RPC paths.

const CLIENT_PEER := RoomOffline.CLIENT_PEER
const CLIENT_ID := RoomOffline.CLIENT_OCCUPANT

## A second person, with no connection. Peer 0, and the thing peer 0 must never mean.
const GUEST_ID := 500002

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby: the netcode")

	_test_wire()
	_test_event_bounds()
	await _test_join()
	await _test_prediction()
	await _test_second_person()
	await _test_leaving()
	await _test_loss()

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


# --- The wire --------------------------------------------------------------

## Every encoder against its decoder.
##
## They have to be exact inverses and nothing can check that for you: an encoder that
## writes a field the decoder does not read produces plausible values for every field
## after it, which is a bug that looks like several unrelated ones.
func _test_wire() -> void:
	_section("the wire")

	var hello := RoomEvents.read_hello(DotNetReader.new(
		RoomEvents.write_hello(4242, 7, 900, 60, Vector2(1800.0, 1120.0))
	))
	_check(bool(hello["ok"]), "a hello round-trips")
	_check(int(hello["occupant_id"]) == 4242, "with the occupant id")
	_check(int(hello["peer_id"]) == 7, "the peer id")
	_check(int(hello["tick"]) == 900, "the tick")
	_check(int(hello["tick_rate"]) == 60, "the tick rate")
	_check(
		Vector2(hello["room_size"]).is_equal_approx(Vector2(1800.0, 1120.0)),
		"and the room's size, which is the one a mismatch is silent about"
	)

	var join := RoomEvents.read_join(DotNetReader.new(
		RoomEvents.write_join(88, "Ada Lovelace", Vector2(-311.0, 204.0), 1767225600)
	))
	_check(bool(join["ok"]), "a join round-trips")
	_check(String(join["name"]) == "Ada Lovelace", "with the name")
	_check(int(join["joined_at"]) == 1767225600, "and the moment they arrived")
	_check(
		Vector2(join["position"]).distance_to(Vector2(-311.0, 204.0)) < 0.05,
		"the position within a quantisation step (%s)" % [join["position"]]
	)

	# Truncated rather than refused, and truncated at the *byte* bound the writer used.
	# A name longer than the field is a name somebody chose, not an attack, and refusing
	# the whole join over it would drop a person from the room.
	var long_name := "x".repeat(200)
	var truncated := RoomEvents.read_join(DotNetReader.new(
		RoomEvents.write_join(1, long_name, Vector2.ZERO, 0)
	))
	_check(
		String(truncated["name"]).length() <= RoomContent.NAME_BYTES,
		"an over-long name is truncated, not refused (%d chars)"
			% String(truncated["name"]).length()
	)

	var spawn := RoomEvents.read_spawn(DotNetReader.new(
		RoomEvents.write_spawn(31, 2, 88, Vector2(120.0, -60.0))
	))
	_check(bool(spawn["ok"]), "a spawn round-trips")
	_check(
		int(spawn["net_id"]) == 31 and int(spawn["peer_id"]) == 2
			and int(spawn["occupant_id"]) == 88,
		"with all three ids, which are three different numbers and are read as such"
	)

	_check(
		RoomEvents.read_occupant(DotNetReader.new(RoomEvents.write_occupant(4242))) == 4242,
		"a leave round-trips"
	)
	_check(
		RoomEvents.read_despawn(DotNetReader.new(RoomEvents.write_despawn(31))) == 31,
		"and a despawn"
	)

	var command := Dot2DCommand.new()
	command.move = Vector2(0.6, -0.8)
	command.aim = Vector2(1, 0)
	command.reach = 240.0

	var packet := RoomNetCommand.new()
	packet.tick = 5
	packet.command = command

	var writer := DotNetWriter.new()
	packet.write(writer)

	var decoded := RoomNetCommand.new()
	decoded.read(DotNetReader.new(writer.to_bytes()))

	_check(decoded.tick == 5, "a command round-trips with its tick")
	_check(
		decoded.command.move.distance_to(command.move) < 0.02,
		"and its move within a quantisation step (%s)" % decoded.command.move
	)
	_done()


## What a hostile peer can put on the wire.
func _test_event_bounds() -> void:
	_section("refusals")

	var bad := RoomEvent.of(RoomEvents.Kind.size() + 3, PackedByteArray())
	_check(not bad.validate().ok, "an unknown event kind is refused")

	var good := RoomEvent.of(RoomEvents.Kind.HELLO, PackedByteArray([1, 2, 3]))
	_check(good.validate().ok, "and a known one is not")

	var ask := RoomRequest.of(RoomEvents.Ask.size() + 1)
	_check(not ask.validate().ok, "an unknown ask is refused")

	# [b]Wire ids have to be the same number on two different machines.[/b]
	# [method DotNetMessageRegistry.seal] assigns them from the sorted type names, and
	# `Array.sort()` on a `StringName` does NOT sort lexicographically — Godot compares
	# StringNames by their interned pointer, which is whatever order the names happened to
	# be created in. Two peers intern them differently, sort them differently, and give
	# the same message type two different ids while computing two different schema hashes.
	#
	# Nothing errors. It was invisible to every suite in this family because they all run
	# both ends in one process, sharing one intern table and therefore one order; a
	# browser client is the first peer that is a separate program, and it saw it at once.
	# Asserting the order is lexicographic is what catches it without two processes.
	# Registered in reverse: `room.request` first, then `room.event`. A registry that
	# sorted by interned pointer would keep that order and hand `room.request` id 0.
	var registry := DotNetMessageRegistry.new()
	registry.register(
		RoomRequest.NAME, RoomRequest, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER
	)
	registry.register(
		RoomEvent.NAME, RoomEvent, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT
	)
	registry.seal()

	_check(
		registry.id_of(RoomEvent.NAME) == 0 and registry.id_of(RoomRequest.NAME) == 1,
		"wire ids follow the names in lexicographic order, not the order they were "
		+ "registered in (event %d, request %d)"
			% [registry.id_of(RoomEvent.NAME), registry.id_of(RoomRequest.NAME)],
		"two peers that disagree about this give one message type two ids, silently"
	)
	_check(
		Array(registry.type_names()) == ["room.event", "room.request"],
		"and the schema the hash is computed over is in that order too (%s)"
			% [registry.type_names()]
	)

	# The one field a client controls that doubles as a speed multiplier, and therefore
	# the most attractive thing in this protocol to inflate. Quantisation bounds each
	# component on its own; it cannot bound the length of the pair.
	var cheat := RoomNetCommand.new()
	cheat.command.move = Vector2(40.0, 40.0)
	cheat.command.reach = 1e9
	cheat.sanitise(RoomContent.TICK_RATE)

	_check(
		cheat.command.move.length() <= 1.0001,
		"a move vector of length 56 is clamped to 1 (%.3f)" % cheat.command.move.length()
	)
	_check(
		cheat.command.reach <= RoomNetCommand.MAX_REACH,
		"and an absurd reach to the wire's own maximum (%.0f)" % cheat.command.reach
	)

	var nan_command := RoomNetCommand.new()
	nan_command.command.move = Vector2(NAN, NAN)
	nan_command.sanitise(RoomContent.TICK_RATE)
	_check(
		nan_command.command.move == Vector2.ZERO,
		"and a NaN move becomes standing still rather than a position nothing can clamp"
	)
	_done()


# --- A session -------------------------------------------------------------

func _offline(latency_ticks: int = 0, loss: float = 0.0) -> RoomOffline:
	var pair := RoomOffline.new()
	pair.name = "Pair%d" % get_child_count()
	pair.latency_ticks = latency_ticks
	pair.loss = loss
	add_child(pair)
	pair.start("Tester")
	return pair


## Runs both ends for [param ticks] simulated ticks.
##
## The client's tick is driven here rather than inside [RoomOffline], because the client
## half is what is under test and a helper that ticked both would hide the ordering — which
## is exactly where the bug would be.
func _pump(pair: RoomOffline, ticks: int, command: Dot2DCommand = null) -> void:
	var step := pair.client_net.clock.tick_duration()

	for _index in range(ticks):
		_ticks[pair] = int(_ticks.get(pair, 0)) + 1

		# The client goes first, and on its own clock. `input_tick()` is ahead of the
		# server by the configured margin, which is the whole reason a command for tick N
		# is in the server's hands before it simulates N. Driving the client from the
		# server's counter instead makes every input arrive exactly one tick late, for
		# ever, and the symptom is a player who moves on their own screen and nowhere
		# else.
		var clock := pair.client_net.clock
		clock.advance(step)

		if clock.is_synced():
			pair.client_bridge.client_tick(clock.input_tick(), command)
		else:
			pair.client_bridge.client_tick(int(_ticks[pair]), command)

		pair.server_tick(int(_ticks[pair]))
		pair.client_net.interpolate_frame()
		await get_tree().process_frame


## Pumps until [param condition] holds, or gives up. Returns whether it happened.
##
## A deadline in ticks rather than "twenty frames is surely enough". How many ticks a
## hello takes depends on the configured latency, and a fixed count passes at zero and
## fails at anything else — which is the worst kind of check, because it looks like a
## real regression.
func _pump_until(pair: RoomOffline, condition: Callable, ticks: int = 240) -> bool:
	for _index in range(ticks):
		if bool(condition.call()):
			return true

		await _pump(pair, 1)

	return bool(condition.call())


## Tick counter per pair, so two sessions in one run do not share a clock.
var _ticks: Dictionary = {}


## Everything a session needs before anything can be asserted about it.
func _joined(pair: RoomOffline) -> bool:
	pair.client_bridge.ask_for_room()
	return await _pump_until(
		pair,
		func() -> bool:
			return pair.client_bridge.local_occupant_id != 0 \
				and pair.client_bridge.behaviour_for(RoomOffline.CLIENT_OCCUPANT) != null
	)


func _test_join() -> void:
	_section("joining")

	var pair := _offline()
	var ready := await _joined(pair)

	_check(ready, "the client is told about the room after asking for it")
	_check(
		pair.client_bridge.local_occupant_id == CLIENT_ID,
		"the hello says who you are (%d)" % pair.client_bridge.local_occupant_id
	)
	_check(
		pair.client_net.local_peer_id == CLIENT_PEER,
		"and which peer (%d)" % pair.client_net.local_peer_id
	)
	_check(
		pair.client_world.occupant_count() == 1,
		"the client's room has one person in it"
	)

	var me := pair.client_world.occupant_for(CLIENT_ID)
	_check(me != null and me.display_name == "Tester", "with the name the server gave")
	_check(me != null and me.is_local, "marked as the local one")
	_check(
		pair.client_bridge.entity_count() == 1,
		"and one replicated entity mirroring them"
	)

	var behaviour := pair.client_bridge.behaviour_for(CLIENT_ID)
	_check(
		behaviour != null and behaviour.identity != null
			and behaviour.identity.is_predicted(),
		"which is predicted, because it is theirs",
		"anything else is walking a full round trip behind your own keyboard"
	)
	_done()


func _test_prediction() -> void:
	_section("prediction")

	# Four ticks each way, which at 60 Hz is the 130 ms round trip of a bad connection.
	var pair := _offline(4)

	if not _check(await _joined(pair), "the session comes up"):
		_done()
		return

	# Toward the middle of the room, whichever corner the deterministic spawn put them
	# in. A fixed direction walks into a wall on some seeds and measures the wall.
	var start := pair.client_world.occupant_for(CLIENT_ID).position()
	var command := Dot2DCommand.new()
	command.move = (pair.client_world.arena.bounds.get_center() - start).normalized()

	await _pump(pair, 90, command)

	var here := pair.client_world.occupant_for(CLIENT_ID)
	var there := pair.server_world.occupant_for(CLIENT_ID)

	_check(
		here.position().distance_to(start) > 40.0,
		"walking moves you on your own screen immediately (%.0f units)"
			% here.position().distance_to(start),
		"a client that waited for the server would feel the whole round trip on every step"
	)
	_check(
		there.position().distance_to(start) > 40.0,
		"and the server agrees you moved (%.0f units)"
			% there.position().distance_to(start),
		"an input stamped for a tick the server has already passed is discarded as late, "
		+ "for ever, with no error on either end"
	)

	# The number this whole design exists for. Two ends running the same motor over the
	# same commands should stay within a few units under 60 ms each way; a correction rate
	# near 0.5 means something is reconciling twice, which is the bug game-arena shipped.
	# [b]While somebody is walking the two ends are meant to disagree.[/b] The client is
	# predicting the lead's worth of motion the server has not simulated yet, which at
	# full speed is exactly `lead x speed / tick_rate` — about 26 units here — and a check
	# that called that drift would be a check that failed when prediction was working.
	# What has to be true is that they converge once the walking stops.
	var lead := pair.client_net.clock.input_tick() - pair.client_net.clock.server_tick()
	var moving_gap := here.position().distance_to(there.position())
	_check(
		moving_gap < float(lead + 2) * 260.0 / 60.0,
		"while walking the client leads the server by %.0f units, which is the lead"
			% moving_gap
	)

	await _pump(pair, 60, Dot2DCommand.new())

	var settled := here.position().distance_to(there.position())
	_check(
		settled < 1.0,
		"and standing still they converge to %.3f units" % settled,
		"anything that does not converge is a simulation the two ends do not share"
	)

	# The number the whole session rests on, asserted directly rather than inferred from
	# the position: the input timeline has to lead the server by the flight time *plus* a
	# margin, not by the margin alone.
	var clock := pair.client_net.clock
	_check(
		clock.input_tick() - clock.server_tick() > clock.one_way_ticks(),
		"the input timeline leads the server by more than the flight time (%d against %d)"
			% [clock.input_tick() - clock.server_tick(), clock.one_way_ticks()]
	)
	_check(
		pair.server_net.input_buffer_for(CLIENT_PEER).late_count < 20,
		"so almost nothing arrives late (%d)"
			% pair.server_net.input_buffer_for(CLIENT_PEER).late_count,
		"every input late is a player who moves on their own screen and nowhere else"
	)

	var rate := pair.client_net.predictor.correction_rate()
	_check(
		rate < 0.25,
		"the correction rate is %.3f" % rate,
		"0.5 is what a second reconciliation pass looks like"
	)
	_done()


func _test_second_person() -> void:
	_section("somebody else")

	var pair := _offline()

	if not _check(await _joined(pair), "the session comes up"):
		_done()
		return

	# Peer 0: somebody in the room with no connection. Registering them as a peer would
	# make the server build a snapshot for the broadcast address and send it to everybody,
	# and `_tell` would send their private hello to every client. Both are guarded, and
	# this is what proves the guard.
	var added := pair.server_bridge.add_occupant(0, GUEST_ID, "Nobody")
	_check(added.ok, "a person with no connection can be in the room")
	_check(
		not pair.server_net.peers().has(0),
		"and is not registered as a peer",
		"peer 0 is the broadcast address, not a peer"
	)

	await _pump(pair, 20)

	_check(
		pair.client_world.occupant_count() == 2,
		"the client is told about them (%d in the room)"
			% pair.client_world.occupant_count()
	)

	var them := pair.client_world.occupant_for(GUEST_ID)
	_check(them != null and them.display_name == "Nobody", "by name")
	_check(them != null and not them.is_local, "and not as the local one")

	var mirror := pair.client_bridge.behaviour_for(GUEST_ID)
	_check(
		mirror != null and mirror.identity != null and not mirror.identity.is_predicted(),
		"their entity is mirrored, not predicted"
	)

	# The interpolated position has to reach the *simulation*, not sit in a replicated
	# property nothing reads. Both other games in this family shipped that bug: the
	# smoothed value was computed correctly and consumed by nothing, and the symptom
	# pointed at the interpolator.
	var walk := Dot2DCommand.new()
	walk.move = Vector2.DOWN
	pair.server_bridge.note_command(GUEST_ID, walk)

	var before := them.position()
	await _pump(pair, 60)

	_check(
		them.position().distance_to(before) > 20.0,
		"and moving them on the server moves them on the client (%.0f units)"
			% them.position().distance_to(before),
		"a value computed and never read looks exactly like a value computed wrongly"
	)
	_done()


func _test_leaving() -> void:
	_section("leaving")

	var pair := _offline()

	if not _check(await _joined(pair), "the session comes up"):
		_done()
		return

	pair.server_bridge.add_occupant(0, GUEST_ID, "Nobody")
	await _pump_until(pair, func() -> bool: return pair.client_world.occupant_count() == 2)

	_check(pair.client_world.occupant_count() == 2, "two people are in the room")

	pair.server_world.remove_occupant(GUEST_ID)
	await _pump_until(pair, func() -> bool: return pair.client_world.occupant_count() == 1)

	_check(
		pair.client_world.occupant_count() == 1,
		"one leaves and the client's room has one person in it"
	)
	_check(
		pair.client_bridge.behaviour_for(GUEST_ID) == null,
		"and their entity is gone, not merely hidden",
		"a world that cleared a dictionary instead of destroying its entities left every "
		+ "client holding the previous round's players for ever"
	)
	_check(
		pair.client_bridge.entity_count() == 1,
		"leaving exactly one entity (%d)" % pair.client_bridge.entity_count()
	)
	_done()


func _test_loss() -> void:
	_section("under loss")

	# A quarter of every snapshot dropped, four ticks each way. Reliable events are not
	# dropped: this loopback has no retransmission, and dropping one would be testing
	# dot-net's reliability layer rather than this game.
	var pair := _offline(4, 0.25)

	if not _check(await _joined(pair), "the session comes up"):
		_done()
		return

	var start := pair.client_world.occupant_for(CLIENT_ID).position()
	var command := Dot2DCommand.new()
	command.move = (pair.client_world.arena.bounds.get_center() - start).normalized()
	await _pump(pair, 120, command)

	# Stopped and settled, for the reason above: a moving client is meant to be ahead.
	await _pump(pair, 90, Dot2DCommand.new())

	var here := pair.client_world.occupant_for(CLIENT_ID)
	var there := pair.server_world.occupant_for(CLIENT_ID)
	var drift := here.position().distance_to(there.position())

	_check(
		drift < 2.0,
		"a quarter of the snapshots dropped still converges to %.3f units" % drift,
		"prediction plus reliable membership is what makes a lossy connection playable"
	)
	_check(
		pair.client_net.predictor.correction_rate() < 0.35,
		"with a correction rate of %.3f"
			% pair.client_net.predictor.correction_rate(),
		"consistently high means the two ends are not running the same simulation"
	)
	_check(
		pair.client_world.occupant_count() == 1,
		"and nobody is lost from the room, because membership is reliable"
	)

	# The server degrades to a conservative view rather than failing when a peer's
	# acknowledgements never arrive, so everything above would still mostly pass with
	# the ack header mis-sized. Ask the server whether it is actually receiving them.
	_check(
		pair.server_net.peer_acks_wired(CLIENT_PEER),
		"and the client's acknowledgements are reaching the server",
		"without them the server keeps the conservative view and never re-sends"
	)
	_done()
