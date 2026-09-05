extends Node

## The room's own suite: membership, movement, bounds and determinism.
##
## [codeblock]
## godot --headless --path . res://examples/headless_room.tscn
## [/codeblock]
##
## Exits non-zero on any failure. No netcode, no server, no rendering — this is
## [RoomWorld] alone, which is the only part of the game that decides anything.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section aborts that
## function and nothing says so: the checks that already ran still print ok, the ones after
## it never happen, and the total at the bottom cannot reveal a check that never ran.
## dot-2d-hungry lost eight checks that way and the reported total went *up*.
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby: the room")

	_test_setup()
	_test_membership()
	_test_capacity()
	_test_walking()
	_test_bounds()
	_test_determinism()
	_test_bubbles()

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


## A world of its own, unregistered, so several can exist in one run.
func _world(scope: StringName) -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "World_%s" % scope
	world.is_authority = true
	world.register_service = false
	world.service_scope = scope
	add_child(world)
	world.setup()
	return world


func _walk(direction: Vector2) -> Dot2DCommand:
	var command := Dot2DCommand.new()
	command.move = direction.normalized()
	return command


# --- Sections --------------------------------------------------------------

func _test_setup() -> void:
	_section("setting up")

	var world := _world(&"setup")

	_check(world.arena != null, "the world builds an arena")
	_check(
		world.arena.bounds.size.is_equal_approx(RoomContent.ROOM_EXTENT * 2.0),
		"the size RoomContent says (%s)" % world.arena.bounds.size
	)
	_check(world.motor != null, "and a motor")
	_check(
		world.motor.body == world.arena.body,
		"whose body is the arena's, so a walker is stopped by the same walls it is "
		+ "clamped to"
	)
	_check(world.occupant_count() == 0, "with nobody in it")
	_done()


func _test_membership() -> void:
	_section("membership")

	var world := _world(&"membership")
	var joins: Array[int] = []
	var leaves: Array[int] = []

	# Captured through an Array, not an int. GDScript lambdas capture locals by value, so
	# a counter incremented inside a handler stays zero outside it — and the test reports
	# a failure for a signal that fired perfectly.
	world.occupant_joined.connect(func(o: RoomOccupant) -> void: joins.append(o.id))
	world.occupant_left.connect(func(o: RoomOccupant) -> void: leaves.append(o.id))

	var first := world.add_occupant(11, "Ada")
	_check(first.ok, "somebody can enter")
	_check(joins == [11], "and the join is announced (%s)" % [joins])

	var again := world.add_occupant(11, "Ada")
	_check(
		not again.ok,
		"the same id cannot enter twice",
		"replacing them would move somebody standing still and lose their bubble"
	)

	world.add_occupant(12, "Grace")
	_check(world.occupant_count() == 2, "two people are in the room")

	var roster := world.roster()
	_check(roster.size() == 2, "the roster lists both")
	_check(
		roster[0].id == 11 and roster[1].id == 12,
		"oldest first, so a list somebody is reading does not reorder itself"
	)

	_check(world.remove_occupant(11), "somebody can leave")
	_check(leaves == [11], "and the leave is announced")
	_check(
		not world.remove_occupant(11), "leaving twice is refused rather than announced"
	)
	_check(world.occupant_count() == 1, "one person is left")
	_done()


func _test_capacity() -> void:
	_section("capacity")

	var world := _world(&"capacity")

	for index in range(RoomContent.MAX_OCCUPANTS):
		world.add_occupant(1000 + index, "P%d" % index)

	_check(
		world.occupant_count() == RoomContent.MAX_OCCUPANTS,
		"the room fills to %d" % RoomContent.MAX_OCCUPANTS
	)

	var overflow := world.add_occupant(9999, "One too many")
	_check(
		not overflow.ok,
		"and refuses the next one",
		"everybody in a lobby is relevant to everybody else, which is what caps it"
	)
	_done()


func _test_walking() -> void:
	_section("walking")

	var world := _world(&"walking")
	world.add_occupant(1, "Walker")

	var occupant := world.occupant_for(1)
	var start := occupant.position()

	for _i in range(30):
		world.tick({1: _walk(Vector2.RIGHT)})

	var moved := occupant.position() - start
	_check(moved.x > 40.0, "half a second of walking moves you (%.0f units)" % moved.x)
	_check(absf(moved.y) < 0.5, "and only in the direction asked for")

	# The command is kept rather than cleared. Somebody who stopped dead on every tick a
	# packet was late would stutter continuously on any connection worth having.
	var before := occupant.position()
	world.tick({})
	_check(
		occupant.position().x > before.x,
		"a tick with no command keeps walking, because the last one is still in force"
	)

	for _i in range(60):
		world.tick({1: Dot2DCommand.new()})

	_check(
		occupant.state.speed() < 1.0,
		"and releasing everything stops you (%.2f u/s)" % occupant.state.speed()
	)
	_done()


func _test_bounds() -> void:
	_section("the walls")

	var world := _world(&"bounds")
	world.add_occupant(1, "Wanderer")

	var occupant := world.occupant_for(1)

	# Long enough to cross the room several times over from anywhere in it.
	for _i in range(600):
		world.tick({1: _walk(Vector2(1.0, 1.0))})

	var at := occupant.position()
	var room := world.arena.bounds
	var radius := occupant.state.radius

	_check(
		at.x <= room.end.x - radius + 0.001 and at.y <= room.end.y - radius + 0.001,
		"walking into the corner does not leave the room (%.1f, %.1f)" % [at.x, at.y]
	)

	# Placed outside by hand and ticked with nothing held. The motor only clamps something
	# that is *moving*; game-blob measured a cell 2.8 units past the wall because of
	# exactly this, and [method RoomWorld.simulate_occupant] clamps unconditionally for
	# that reason.
	occupant.state.position = room.end + Vector2(500.0, 500.0)
	occupant.state.velocity = Vector2.ZERO
	world.tick({1: Dot2DCommand.new()})

	at = occupant.position()
	_check(
		at.x <= room.end.x - radius + 0.001 and at.y <= room.end.y - radius + 0.001,
		"and somebody standing still outside it is put back (%.1f, %.1f)" % [at.x, at.y]
	)
	_done()


func _test_determinism() -> void:
	_section("determinism")

	# The property everything else rests on: a client predicting a walk and a server
	# re-running the same commands must reach the same position, or every tick is a
	# correction. Two worlds, the same ids, the same commands, no shared state.
	var a := _world(&"det_a")
	var b := _world(&"det_b")

	for world in [a, b]:
		world.add_occupant(7, "Twin")
		world.add_occupant(8, "Other")

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260829
	var script: Array[Dictionary] = []

	for _i in range(240):
		script.append({
			7: _walk(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))),
			8: _walk(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))),
		})

	for frame in script:
		a.tick(frame)
		b.tick(frame)

	var drift := 0.0

	for id in [7, 8]:
		drift = maxf(
			drift, a.occupant_for(id).position().distance_to(b.occupant_for(id).position())
		)

	_check(
		drift == 0.0,
		"two worlds replaying the same commands are bit-identical (drift %.9f)" % drift,
		"anything above zero here is a prediction that will never converge"
	)

	_check(
		a.current_tick() == b.current_tick() and a.current_tick() == script.size(),
		"and both counted the same ticks (%d)" % a.current_tick()
	)
	_done()


func _test_bubbles() -> void:
	_section("chat bubbles")

	var world := _world(&"bubbles")
	world.add_occupant(1, "Talker")

	var occupant := world.occupant_for(1)
	var now := 100000

	_check(not occupant.has_bubble(now), "nobody starts out saying anything")

	occupant.say("hello", now)
	_check(occupant.has_bubble(now), "saying something shows one")
	_check(
		not occupant.has_bubble(now + 20000),
		"and it goes away (%d ms)" % (occupant.bubble_until_ms - now)
	)

	occupant.say("a", now)
	var short_life := occupant.bubble_until_ms - now
	occupant.say("a".repeat(200), now)
	var long_life := occupant.bubble_until_ms - now

	_check(
		long_life > short_life,
		"a longer line stays up longer (%d ms against %d)" % [long_life, short_life]
	)
	_check(
		long_life <= 7000,
		"but not indefinitely — the text comes from another player (%d ms)" % long_life
	)
	_done()
