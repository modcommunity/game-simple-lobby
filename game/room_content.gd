class_name RoomContent
extends RefCounted

## Every constant the room is made of, in one file both ends read.
##
## [b]Nothing here may be configured per peer.[/b] The room's size is quantised into the
## wire format, the palette decides what colour a stranger is on your screen, and the
## walk speed is what a client predicts with — three values that are silently catastrophic
## when two machines disagree and produce no error on either. dot-2d-hungry learned the
## first one the expensive way: a client holding a different arena rectangle derives every
## crumb somewhere else, from the right seed, so the ids match, the counts match, and
## nothing is where anybody says it is.
##
## A server that wants a different room ships a different pack. It does not send numbers.

## Half-width and half-height of the room, in world units.
##
## Small on purpose. A lobby is a place you can see all of at once — a room you have to
## walk across to find out who is in it is a room where the roster is the only thing
## anybody reads.
const ROOM_EXTENT := Vector2(900.0, 560.0)

## The room, as a rectangle. What [Dot2DArena] is given and what positions are clamped to.
static func bounds() -> Rect2:
	return Rect2(-ROOM_EXTENT, ROOM_EXTENT * 2.0)


## How big a person is.
const OCCUPANT_RADIUS := 22.0

## Simulation rate. Matched by the module against `sv_tickrate`, loudly, because a
## mismatch is a room that runs at the wrong speed with nothing in the log about it.
const TICK_RATE := 60

## Snapshots a second.
##
## Lower than a shooter's, deliberately: nobody is being shot at. Twenty people at
## [constant Dot2DNetSync.estimated_bits] is about 250 bytes a snapshot, so 15 Hz is under
## 4 kB/s to everybody in the room — which matters, because every one of them is on a
## WebSocket where a snapshot cannot be dropped and a slow client stalls the ones behind
## it.
const SNAPSHOT_RATE := 15

## Longest display name kept. Also the wire's bound.
const NAME_BYTES := 32

## People in one room.
##
## The number that makes "everybody is always relevant" affordable — see
## [RoomBridge._build_occupant_entity]. Past this a lobby needs interest management and
## stops being a lobby.
const MAX_OCCUPANTS := 64


## How a person moves.
##
## Top-down and direct: WASD or a drag, no momentum to speak of, no aim. A lobby is a
## place you walk about in while you read the chat, and anything with inertia makes
## standing still a skill.
static func tunables() -> Dot2DTunables:
	var t := Dot2DTunables.new()
	t.mode = Dot2DTunables.Mode.TOPDOWN
	t.max_speed = 260.0
	# High enough that a tap moves you and a release stops you inside two ticks. Sliding
	# to a halt in a chat room reads as lag rather than as physics.
	t.acceleration = 3200.0
	t.friction = 3000.0
	t.turn_authority = 1.0
	# The pointer drives movement on a touchscreen, and does not on a desktop: see
	# [RoomInput], which fills `move` from keys and `aim`/`reach` from a drag. Both end up
	# in the same command and the motor reads whichever is set.
	t.follow_aim = false
	t.bounce_off_walls = false
	return t


## The colour a person is drawn in, derived from their id.
##
## [b]Derived, not assigned and not replicated.[/b] A colour that travelled would be one
## more thing to get out of step on a rejoin, and a colour a server chose would have to be
## remembered across a game change. Two people in one room can collide on a hue; nobody
## has ever minded, and the name is drawn above them anyway.
##
## The multiplier is a large odd number so consecutive session ids — which is exactly what
## a dedicated server hands out — land far apart on the wheel rather than in a gradient.
static func colour_for(id: int) -> Color:
	var hue := float((absi(id) * 2654435761) % 360) / 360.0
	return Color.from_hsv(hue, 0.55, 0.95)


## The floor's grid spacing. Drawn, and nothing else: the room has no cells.
const FLOOR_GRID := 80.0


## The netcode's settings, in one place both ends read.
##
## [b]Built here rather than three times.[/b] A server, a client and the offline pair each
## need one, and any field they disagree about is a field that decodes to a different
## value on the two ends — silently, because a bit-packed reader cannot tell a wrong range
## from a right one. [param authority] is the only thing that differs.
##
## [param authority] is [Variant]-free on purpose: everything else about the two roles is
## the manager's, not the config's.
static func net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = TICK_RATE
	config.snapshot_rate = SNAPSHOT_RATE

	# [b]Larger than dot-net's default, and it has to be.[/b] A replicated position is
	# quantised to [constant Dot2DNetSync.POSITION_BITS] bits over
	# ±[constant Dot2DNetSync.WORLD_EXTENT], which is a step of about 0.016 units — bigger
	# than the 0.01 default. Left alone, every single reconciliation measures the
	# quantisation as an error, `correction_rate()` reads ~1.0 whether or not anything is
	# wrong, and the one number that says whether prediction is working says nothing.
	# 0.05 is [method Dot2DState.matches]'s own tolerance, chosen for the same reason.
	config.reconcile_position_epsilon = 0.05

	# Nothing in a lobby is a hitscan shot and nothing is disputed, so rewinding the world
	# would change an outcome nobody is arguing about. Off, and said here rather than left
	# at whatever the default happens to be.
	config.enable_lag_compensation = false
	return config
