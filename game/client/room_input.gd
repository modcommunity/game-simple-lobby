class_name RoomInput
extends Node

## Turns a keyboard, a mouse or a finger into one [Dot2DCommand] a tick.
##
## Separate from the simulation for dot-2d's reason: the motor must be a pure function of
## (state, command, delta), so a client predicting a walk and a server re-running it reach
## the same answer. Nothing in [RoomWorld] reads a device, and nothing here decides
## anything.
##
## [b]The keys are read directly rather than through the input map.[/b] This game is
## delivered as a dot-cloud pack and instantiated inside a host application's tree — an
## InputMap is project-wide state that a pack cannot carry and must not silently expect,
## and a movement key that worked in the standalone build and did nothing in the shell
## would be a bug with no error anywhere. Arrow keys go through `ui_*`, which every Godot
## project has by construction.

## Keys that mean "walk". Physical, so WASD is WASD on AZERTY too.
const KEYS_LEFT: Array[Key] = [KEY_A]
const KEYS_RIGHT: Array[Key] = [KEY_D]
const KEYS_UP: Array[Key] = [KEY_W]
const KEYS_DOWN: Array[Key] = [KEY_S]

## Furthest a drag can mean, in world units. Also [constant RoomNetCommand.MAX_REACH]'s
## sibling: the sampler clamps and the server clamps again.
const MAX_REACH := 1200.0

## Below this, a pointer means "stop" rather than a direction.
##
## Without it, releasing a drag one pixel from where you are makes you jitter in place:
## the direction of a one-pixel offset is noise, and it is a different noise every frame.
const DEAD_REACH := 8.0

## Whether this sampler is allowed to produce anything.
##
## False while a text field has the keyboard — which in a chat room is most of the time,
## and typing "was" walking you across the room is the single most obvious thing that can
## go wrong here.
var enabled: bool = true

## Where the local person is, in world units. Set every frame by [RoomClient].
##
## The pointer is measured from *them*, not from the screen, because a screen position is
## meaningless on a server: it depends on a window size and a camera zoom the server does
## not have. A world offset is not, and the server recovers the point by adding the same
## offset to the same centre.
var centre: Vector2 = Vector2.ZERO

## Where a command comes from instead of a device.
##
## Signature: [code]func() -> Dot2DCommand[/code]. Unset — which is every person playing —
## the keyboard and the pointer are read as usual.
##
## [b]The seam bots, demo playback and tests plug into.[/b] It is here rather than in the
## client because the whole point of separating sampling from simulation is that the motor
## never learns where a command came from; a test that drove the client's tick directly
## instead would be fighting the client's own [code]_physics_process[/code], which is
## sending "stopped" on the same frames.
var command_source: Callable = Callable()

## Whether a drag is in progress. Set from [method handle_event].
var _dragging: bool = false
var _drag_at: Vector2 = Vector2.ZERO


## One tick of intent.
##
## Keys and the pointer both fill the command, and the motor reads `move` first — so a
## player holding W while dragging walks the way the key says. That is the right
## precedence: a key is a deliberate press and a drag is where a hand happens to be.
func sample(viewport: Viewport, camera: Camera2D) -> Dot2DCommand:
	if command_source.is_valid():
		var supplied: Variant = command_source.call()
		return supplied if supplied is Dot2DCommand else Dot2DCommand.new()

	var command := Dot2DCommand.new()

	if not enabled:
		return command

	var move := Vector2.ZERO

	if _any_pressed(KEYS_LEFT) or Input.is_action_pressed(&"ui_left"):
		move.x -= 1.0
	if _any_pressed(KEYS_RIGHT) or Input.is_action_pressed(&"ui_right"):
		move.x += 1.0
	if _any_pressed(KEYS_UP) or Input.is_action_pressed(&"ui_up"):
		move.y -= 1.0
	if _any_pressed(KEYS_DOWN) or Input.is_action_pressed(&"ui_down"):
		move.y += 1.0

	if move != Vector2.ZERO:
		command.move = move.normalized()

	if _dragging and viewport != null:
		var world := _to_world(viewport, camera, _drag_at)
		var offset := world - centre
		var distance := offset.length()

		if distance > DEAD_REACH:
			command.aim = offset / distance
			command.reach = minf(distance, MAX_REACH)

			# A drag with no key held is the movement. Filling `move` as well — rather
			# than relying on the motor's pointer mode — keeps one code path in the motor
			# and makes a keyboard and a finger produce the same kind of command, which is
			# what stops the two feeling different.
			if command.move == Vector2.ZERO:
				command.move = command.aim * clampf(distance / 160.0, 0.0, 1.0)

	command.sanitise(MAX_REACH)
	return command


## Feeds a raw event in. Call from the client's `_unhandled_input`.
##
## Only touches and mouse drags: everything else is polled in [method sample], because a
## key held across a tick boundary has to produce a command on every tick and an event
## only arrives once.
func handle_event(event: InputEvent) -> void:
	if not enabled:
		_dragging = false
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
			_drag_at = button.position
	elif event is InputEventMouseMotion and _dragging:
		_drag_at = (event as InputEventMouseMotion).position
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_dragging = touch.pressed
		_drag_at = touch.position
	elif event is InputEventScreenDrag:
		_dragging = true
		_drag_at = (event as InputEventScreenDrag).position


## Stops any drag. Called when the chat entry takes focus, and on disconnect.
##
## Not merely tidiness: a drag that was in progress when a menu opened is a drag nothing
## will ever end, and the person walks into a wall until they click again.
func release() -> void:
	_dragging = false


func is_dragging() -> bool:
	return _dragging


func _any_pressed(keys: Array[Key]) -> bool:
	for key in keys:
		if Input.is_physical_key_pressed(key):
			return true

	return false


## Screen position to world position.
##
## Through the camera's own transform rather than by arithmetic on its zoom, so this stays
## correct when the camera is re-fitted to a resized window — which happens every time
## somebody rotates a phone.
func _to_world(viewport: Viewport, camera: Camera2D, at: Vector2) -> Vector2:
	if camera != null and camera.is_inside_tree():
		return camera.get_canvas_transform().affine_inverse() * at

	return viewport.get_canvas_transform().affine_inverse() * at
