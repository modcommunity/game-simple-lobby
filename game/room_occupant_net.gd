class_name RoomOccupantNet
extends DotNetBehaviour

## The thirty lines [Dot2DNetSync] says belong in the game.
##
## [b]dot-2d may not name a dot-net class.[/b] A script that so much as mentions a missing
## [code]class_name[/code] fails to parse and takes every script that references it down
## with it, so dot-2d has to compile with dot-core alone. What it ships instead is a
## description of what to replicate as [i]data[/i] — property names, and type names as
## strings. Resolving those strings against [enum DotNetVar.Type] is this file's job.
##
## One behaviour per occupant, one entity per occupant. In a lobby that mapping is exact:
## a person is one circle and is never in two places.

## The person this replicates. Set by [RoomBridge] before registration.
var occupant: RoomOccupant = null

## The bridge, so the authority can drive the whole room exactly once per tick.
var bridge: RoomBridge = null

# --- From Dot2DNetSync.specs() ---
var net_position: Vector2 = Vector2.ZERO
var net_velocity: Vector2 = Vector2.ZERO
var net_mass: int = 0
var net_flags: int = 0

## Newest tick whose state this behaviour has adopted. Client side, for reconciliation.
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in Dot2DNetSync.specs():
		var property: StringName = spec["property"]
		var declaration: DotNetVar = null

		if bool(spec["custom"]):
			# Position and velocity are two components, not three. dot-net's quantised
			# vector types are Vector3, and paying for a Z that is always zero wastes 40%
			# of the position bandwidth for nothing.
			if property == &"net_position":
				declaration = replicate_custom(
					property,
					Dot2DNetSync.write_position,
					Dot2DNetSync.read_position
				)
			else:
				declaration = replicate_custom(
					property,
					Dot2DNetSync.write_velocity,
					Dot2DNetSync.read_velocity
				)
		else:
			declaration = replicate(property, DotNetVar.Type[spec["type"]])

			if int(spec["bits"]) > 0:
				declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

	# Position is what everything else is judged against: a stale mass looks like a
	# slightly wrong number, a stale position looks like a teleport.
	var position_var := find_var(&"net_position")

	if position_var != null:
		position_var.with_priority(4.0)


# --- Input -----------------------------------------------------------------

## Takes one tick of a peer's intent.
##
## Already sanitised: [method DotNetManager._apply_input] calls
## [method DotNetInput.sanitise] before this runs, on the server, because everything in it
## came from a client.
func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as RoomNetCommand

	if command == null or bridge == null or occupant == null:
		return

	bridge.note_command(occupant.id, command.command)


# --- Simulation ------------------------------------------------------------

## Advances this person by one tick, on whichever machine is entitled to.
##
## On the authority the whole room ticks as one, driven by the first behaviour to reach
## this on a given tick; the rest find it done and only copy their own state out. That
## pattern costs one integer comparison and it is what keeps every occupant on the same
## tick — a room where one person moved before another had is a room where two people can
## occupy the same square, once, and then disagree about it forever.
##
## On a predicting client this runs the motor for this occupant and nothing else, which is
## the only shape a reconciliation replay converges for.
func _net_simulate(tick: int, delta: float) -> void:
	if occupant == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_room_ticked(tick)
	elif bridge != null:
		bridge.predict_occupant(occupant, tick, delta)

	pull()


## Copies the simulation into the replicated properties, and onto the node.
##
## The node's position is not decoration: [method DotNetIdentity.world_position] reads it,
## and that is what prioritisation is computed from. An occupant whose node never moved
## would be judged from wherever they spawned.
func pull() -> void:
	if occupant == null:
		return

	Dot2DNetSync.pull(occupant.state, self)

	var node := identity.entity as Node2D if identity != null else null

	if node != null:
		node.position = occupant.state.position


## Copies received state back into the simulation. Receiving side.
##
## Runs for a remote occupant, where it is the only thing that moves them, and for the
## owning client, where it is the rewind half of reconciliation — the server's answer is
## adopted wholesale and [DotNetPredictor] replays every unacknowledged command on top of
## it.
func _net_state_applied(tick: int) -> void:
	if occupant == null:
		return

	last_state_tick = tick
	Dot2DNetSync.push(self, occupant.state)

	# The radius is not replicated and not derived from mass here: everybody in a lobby is
	# the same size, and [method Dot2DNetSync.push] leaves it alone when no mass rules are
	# given. Restating it would be a second copy of a constant both ends already have.
	occupant.state.radius = RoomContent.OCCUPANT_RADIUS

	# [b]The node is not moved on a predicted entity, and that is not an optimisation.[/b]
	# [method DotNetManager.receive_snapshot] calls this — through `read_state` — *before*
	# it calls [method DotNetPredictor.reconcile], and the first thing reconcile does is
	# capture the node as "what the client is currently showing", to measure how wrong the
	# prediction was. Writing the server's position there first makes that capture the
	# server's position, so the measured error is the entire replay distance rather than
	# the disagreement: the correction rate reads ~1.0, every reconciliation logs a snap,
	# and the number that is supposed to say whether prediction is working says only how
	# far ahead the client is. The simulation is right the whole time, which is what makes
	# it hard to see.
	#
	# The replay writes the node itself, through [method pull], one tick at a time.
	if identity == null or identity.is_predicted():
		return

	var node := identity.entity as Node2D

	if node != null:
		node.position = occupant.state.position


## Copies the interpolated position into the simulation, every frame, on a remote person.
##
## [b]Without this the interpolator's work is thrown away.[/b]
## [method _net_state_applied] runs when a snapshot arrives — fifteen times a second — and
## it is the only other place `net_position` is read. Somebody driven only by that walks
## in 15 Hz steps while the smooth value sits in a property nothing reads. It looks like
## the interpolator is broken; it is not, it is unread. Both other games in this family
## had exactly this bug.
##
## Deliberately not the bookkeeping half: [member last_state_tick] is what reconciliation
## rewinds to, and the tick here is a *render* tick behind the server's. Recording it
## would rewind a prediction to a tick the server never sent, which is why dot-net does
## not call this on a predicted entity at all.
func _net_interpolated(_tick: int) -> void:
	if occupant == null:
		return

	Dot2DNetSync.push(self, occupant.state)
	occupant.state.radius = RoomContent.OCCUPANT_RADIUS

	var node := identity.entity as Node2D if identity != null else null

	if node != null:
		node.position = occupant.state.position


func describe() -> Dictionary:
	return {
		"occupant": occupant.id if occupant != null else 0,
		"name": occupant.display_name if occupant != null else "",
		"position": net_position,
		"state_tick": last_state_tick,
	}
