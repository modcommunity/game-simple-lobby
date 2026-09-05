class_name RoomRenderer
extends Node2D

## Draws the room and everybody in it.
##
## [b]Ships no art.[/b] dot-ui ships no art and dot-2d draws nothing; this follows both.
## Everything here is a rectangle, a circle or a string, which is what makes the whole
## game a pack small enough to be worth downloading and what stops a lobby needing an
## artist before it can be stood in.
##
## It reads the world and never writes to it. A renderer that nudged a position would be a
## renderer that fought the interpolator, and the symptom is a stutter nobody can locate.

## The room this draws. Set by [RoomClient].
var world: RoomWorld = null

## Which occupant is the local one, so they can be marked. Zero before the hello.
var local_occupant_id: int = 0

@export_group("Palette")

@export var floor_colour: Color = Color(0.10, 0.11, 0.14, 1.0)
@export var grid_colour: Color = Color(1.0, 1.0, 1.0, 0.045)
@export var wall_colour: Color = Color(0.35, 0.62, 0.85, 0.85)
@export var name_colour: Color = Color(0.93, 0.94, 0.96, 1.0)
@export var bubble_colour: Color = Color(0.96, 0.97, 0.99, 0.94)
@export var bubble_text_colour: Color = Color(0.08, 0.09, 0.11, 1.0)

## Font used for names and bubbles. Godot's default when unset.
var _font: Font = null
var _font_size: int = 14


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_font_size = ThemeDB.fallback_font_size


func _process(_delta: float) -> void:
	# Redrawn every frame rather than on a signal. Everybody in the room is moving under
	# an interpolator that produces a new position on every frame and emits nothing, so
	# there is no signal to redraw on — and a lobby with sixty-four circles in it is not
	# where a frame budget goes.
	queue_redraw()


func _draw() -> void:
	if world == null or world.arena == null:
		return

	var bounds := world.arena.bounds

	draw_rect(bounds, floor_colour, true)
	_draw_grid(bounds)
	draw_rect(bounds, wall_colour, false, 3.0)

	var now := Time.get_ticks_msec()

	# Sorted by Y so somebody standing in front of somebody else is drawn in front. Cheap
	# at this population, and the alternative — an arbitrary dictionary order — makes two
	# overlapping people flicker past each other every time the dictionary rehashes.
	var occupants := world.roster()
	occupants.sort_custom(
		func(a: RoomOccupant, b: RoomOccupant) -> bool:
			return a.position().y < b.position().y
	)

	for occupant in occupants:
		_draw_occupant(occupant, now)

	for occupant in occupants:
		# A second pass, so a bubble is never covered by somebody who happens to be
		# standing lower down. Speech is the one thing in this room that must be readable.
		if occupant.has_bubble(now):
			_draw_bubble(occupant, now)


func _draw_grid(bounds: Rect2) -> void:
	var step := RoomContent.FLOOR_GRID
	var x := ceilf(bounds.position.x / step) * step

	while x < bounds.end.x:
		draw_line(Vector2(x, bounds.position.y), Vector2(x, bounds.end.y), grid_colour, 1.0)
		x += step

	var y := ceilf(bounds.position.y / step) * step

	while y < bounds.end.y:
		draw_line(Vector2(bounds.position.x, y), Vector2(bounds.end.x, y), grid_colour, 1.0)
		y += step


func _draw_occupant(occupant: RoomOccupant, _now: int) -> void:
	var at := occupant.position()
	var radius := occupant.state.radius
	var colour := occupant.colour()

	# A soft shadow, so a circle on a flat floor reads as a person standing on it rather
	# than as a hole in it.
	draw_circle(at + Vector2(0.0, radius * 0.35), radius * 0.95, Color(0, 0, 0, 0.25))
	draw_circle(at, radius, colour)

	# Which way they are facing, as a notch. The only thing that makes a circle feel like
	# somebody rather than a token — and it comes free: the motor already tracks facing.
	var facing := Vector2.RIGHT.rotated(occupant.state.facing)
	draw_circle(at + facing * radius * 0.55, radius * 0.26, colour.lightened(0.55))

	if occupant.id == local_occupant_id:
		# A ring rather than a different colour, because the colour is how everybody else
		# recognises you and changing it for one viewer means no two people see the same
		# room.
		draw_arc(at, radius + 5.0, 0.0, TAU, 32, Color(1, 1, 1, 0.85), 2.0)

	var text := occupant.display_name

	if text == "":
		return

	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	var baseline := at + Vector2(-width * 0.5, -radius - 10.0)

	# Drawn twice, offset, rather than with an outline: the room's floor is dark and a
	# name can also cross somebody's bright circle, and a one-pixel shadow is legible on
	# both without a font resource the pack would have to carry.
	draw_string(
		_font, baseline + Vector2(1, 1), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(0, 0, 0, 0.7)
	)
	draw_string(
		_font, baseline, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, name_colour
	)


func _draw_bubble(occupant: RoomOccupant, now: int) -> void:
	var text := occupant.bubble_text
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	var padding := Vector2(8.0, 5.0)
	var at := occupant.position()
	var box := Rect2(
		at + Vector2(-size.x * 0.5 - padding.x, -occupant.state.radius - 30.0 - size.y),
		size + padding * 2.0
	)

	# Fades out over its last half second rather than vanishing. A bubble that disappears
	# between two frames reads as a message that was deleted.
	var remaining := float(occupant.bubble_until_ms - now)
	var alpha := clampf(remaining / 500.0, 0.0, 1.0)

	draw_rect(box, Color(bubble_colour, bubble_colour.a * alpha), true)
	draw_string(
		_font,
		box.position + padding + Vector2(0.0, size.y * 0.78),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_font_size,
		Color(bubble_text_colour, alpha)
	)
