class_name RoomClient
extends Node2D

## Everything a person sees, in one scene.
##
## [b]This is what a host application instantiates.[/b] It is
## [member DotGameDescriptor.client_scene], so a generic client shell that downloaded and
## mounted this pack adds it under [DotClientLink] and gets a playable lobby — no code in
## the shell knows anything about a room.
##
## It owns a mirroring [RoomWorld], a client-side [DotNetManager] and a [RoomBridge], and
## it drives them from [code]_physics_process[/code]. Two of those it also builds for
## itself when there is nothing to connect to, which is what `--offline` is: the same
## scene with a server in the same tree.
##
## [b]The camera does not follow anybody.[/b] The room is smaller than a screen at a
## sensible zoom, and a lobby where you cannot see who is standing behind you is a lobby
## whose roster is the only thing anybody reads. So the whole room is framed, always, and
## re-framed when the window changes.

const CHANNEL := "room.client"

## What a person is called when nothing has told us otherwise.
const DEFAULT_NAME := "Guest"

## Margin around the room when the camera frames it, as a fraction of the room.
const CAMERA_MARGIN := 0.06

## The link this client talks to a server through.
##
## Set by whoever built this scene, before it enters the tree. A generic client shell that
## mounted this pack does not know what a room is, so when it is left null the link is
## looked up in [DotRegistry] instead — which is right for the one-client case and wrong
## for any process holding two, where only one of them can hold the name. Anything running
## two clients sets this explicitly; `examples/sandbox.tscn` does.
##
## Null with nothing registered means offline: there is no server, and
## [method _build_offline] stands one up in this tree instead.
var link: DotClientLink = null

var world: RoomWorld = null
var net: DotNetManager = null
var bridge: RoomBridge = null

var input: RoomInput = null
var renderer: RoomRenderer = null
var ui: RoomUi = null

var _camera: Camera2D = null
var _tick: int = 0
var _roster_dirty: bool = true
var _roster_drawn_at: int = 0

## Whether the initial roster has finished arriving.
##
## Joins are announced only after it has. Otherwise every connect opens with a wall of
## "X joined" for people who were already standing there — wrong, and the loudest thing
## on the screen at the moment somebody is trying to read the room.
var _roster_ready: bool = false

## An offline session's own server half, when there is one. Null in every real deployment.
var _offline: RoomOffline = null


func _ready() -> void:
	_build_view()

	# The link is found rather than required. A client scene instantiated by a shell has
	# one; the same scene run from `examples/play.tscn --offline` does not, and the
	# difference must not be two scenes.
	if link == null:
		link = DotRegistry.get_node_service(DotClientLink.SERVICE) as DotClientLink

	if link != null:
		_build_online()
	else:
		_build_offline()

	get_viewport().size_changed.connect(_frame_room)
	_frame_room()


func _exit_tree() -> void:
	if link != null and is_instance_valid(link):
		if link.chat_received.is_connected(_on_chat):
			link.chat_received.disconnect(_on_chat)
		if link.disconnected.is_connected(_on_disconnected):
			link.disconnected.disconnect(_on_disconnected)


# --- Building --------------------------------------------------------------

func _build_view() -> void:
	_camera = Camera2D.new()
	_camera.name = "Camera"
	_camera.enabled = true
	add_child(_camera)

	renderer = RoomRenderer.new()
	renderer.name = "Renderer"
	add_child(renderer)

	input = RoomInput.new()
	input.name = "Input"
	add_child(input)

	var layer := CanvasLayer.new()
	layer.name = "Ui"
	add_child(layer)

	ui = RoomUi.new()
	ui.name = "Room"
	layer.add_child(ui)

	ui.chat_submitted.connect(_on_chat_submitted)
	# The one wiring that matters: while a text field has the keyboard, WASD is text.
	ui.typing_changed.connect(func(typing: bool) -> void:
		input.enabled = not typing
		if typing:
			input.release()
	)


## The normal case: a mirroring world behind a real connection.
func _build_online() -> void:
	world = _make_world()
	renderer.world = world

	var config := RoomContent.net_config()
	config.tick_rate = world.tick_rate

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	# Replaced by the hello. Until then nothing is sent, because nothing has been spawned.
	net.local_peer_id = 0
	net.config = config
	net.config_file = ""
	net.auto_tick = false
	add_child(net)

	var ready := net.setup()

	if not ready.ok:
		DotLog.error(CHANNEL, "the netcode would not start", {"error": str(ready.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	bridge = RoomBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(world, net, link)

	if not attached.ok:
		DotLog.error(CHANNEL, "the bridge would not attach", {"error": str(attached.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	net.start()
	_connect_bridge()

	# Where the clock learns how long the link is. dot-net never touches a transport and
	# cannot measure this itself; dot-server already does, through its heartbeat. Fed
	# nothing, the clock assumes an instant connection and stamps every command for a tick
	# the server has already simulated — see [member RoomBridge.rtt_source].
	bridge.rtt_source = func() -> float:
		return float(maxi(0, link.ping_ms()))

	link.chat_received.connect(_on_chat)
	link.disconnected.connect(_on_disconnected)

	ui.set_status("Joining the room…")

	# [b]Nothing may be sent to us before we say we exist.[/b] dot-server's signon
	# finished and *then* this scene was built; anything the server sent in between landed
	# on a node that did not exist. This is the first thing that goes the other way, and
	# it is what makes the roster arrive at all.
	bridge.ask_for_room()


func _connect_bridge() -> void:
	bridge.hello_received.connect(func(occupant_id: int) -> void:
		renderer.local_occupant_id = occupant_id
		_roster_dirty = true
	)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.roster_complete.connect(func() -> void:
		ui.set_status("")
		_roster_dirty = true
		_roster_ready = true
	)


## `--offline`: a server and a client in one tree, with a loopback between them.
##
## Not a mode the deployed game has. It exists so the room can be looked at, and drawn,
## without a socket — and because a scene that can only be run by connecting to something
## is a scene nobody checks.
func _build_offline() -> void:
	_offline = RoomOffline.new()
	_offline.name = "Offline"
	add_child(_offline)

	var built := _offline.start(DEFAULT_NAME)

	if not built.ok:
		DotLog.error(CHANNEL, "offline room failed", {"error": str(built.error)})
		ui.set_status("This room could not start.", Color(1.0, 0.5, 0.5))
		return

	world = _offline.client_world
	net = _offline.client_net
	bridge = _offline.client_bridge
	renderer.world = world

	_connect_bridge()
	ui.set_status("Offline — nobody else can see this room.", Color(0.8, 0.75, 0.5))
	bridge.ask_for_room()


## A mirroring world for this client.
##
## [b]Not published in [DotRegistry].[/b] Nothing on a client looks a room up by name —
## only a server-side module does, to find the world a game scene created — and two
## clients in one process would collide on the entry, leaving one of them invisible to
## whatever asked. `examples/sandbox.tscn` runs exactly that, and dot-platform's sandbox
## proved two clients in one tree is a shape this family has to support.
func _make_world() -> RoomWorld:
	var made := RoomWorld.new()
	made.name = "World"
	made.is_authority = false
	made.tick_rate = RoomContent.TICK_RATE
	made.register_service = false
	add_child(made)
	return made


# --- The frame -------------------------------------------------------------

## One or more simulation ticks, driven by the netcode's clock.
##
## [b]The clock is what puts the input ahead of the server.[/b] A command for tick N has
## to be in the server's hands *before* it simulates N, so a client running level with the
## server has every input arrive one tick late — for ever, with no error, and the only
## symptom is a player who cannot move while moving perfectly on their own screen. A
## private frame counter is exactly that mistake, and it is what this used to be.
func _physics_process(delta: float) -> void:
	if bridge == null or net == null or world == null:
		return

	var me := bridge.local_occupant()

	if me != null:
		input.centre = me.position()

	var command := input.sample(get_viewport(), _camera)

	for _step in range(net.clock.advance(delta)):
		if _offline != null:
			# Offline the client *is* the authority's neighbour and there is nothing to
			# be ahead of, so both halves run on the same number. The lead exists to
			# cover a network that is not there.
			_tick += 1
			bridge.client_tick(_tick, command)
			_offline.server_tick(_tick)
		elif net.clock.is_synced():
			bridge.client_tick(net.clock.input_tick(), command)


func _process(_delta: float) -> void:
	if net != null:
		# Every frame, not every tick: this is what turns fifteen snapshots a second into
		# smooth motion, and it is sampled at the render tick rather than the simulation
		# one. Skipping it on a frame is a frame everybody else stands still for.
		net.interpolate_frame()

	# The roster's "here for" column changes once a second, so it is rebuilt at most that
	# often — and immediately when somebody arrives or leaves. Rebuilding sixty-four
	# labels at 144 Hz would be the most expensive thing in this game by an order of
	# magnitude.
	var now := Time.get_ticks_msec()

	if _roster_dirty or now - _roster_drawn_at > 1000:
		_roster_dirty = false
		_roster_drawn_at = now

		if world != null and ui != null:
			ui.set_roster(world.roster(), bridge.local_occupant_id if bridge != null else 0)


func _unhandled_input(event: InputEvent) -> void:
	if input != null:
		input.handle_event(event)


## Fits the whole room in the window.
##
## Recomputed on every resize because a browser tab is resized constantly — and because a
## phone rotating is a resize, and a camera that kept its zoom would show a quarter of the
## room in portrait with no indication that there was any more of it.
func _frame_room() -> void:
	if _camera == null or world == null or world.arena == null:
		return

	var room := world.arena.bounds.size * (1.0 + CAMERA_MARGIN * 2.0)
	var view := Vector2(get_viewport_rect().size)

	if room.x <= 0.0 or room.y <= 0.0 or view.x <= 0.0 or view.y <= 0.0:
		return

	# The *smaller* ratio, so the whole room fits rather than filling the window. Taking
	# the larger one crops, and a person standing in a cropped corner is a person nobody
	# can see talking.
	var scale := minf(view.x / room.x, view.y / room.y)
	_camera.zoom = Vector2(scale, scale)
	_camera.position = world.arena.bounds.get_center()


# --- Chat ------------------------------------------------------------------

func _on_chat_submitted(text: String) -> void:
	if link != null:
		link.send_chat(text)
	elif _offline != null:
		# Offline there is nothing to send it to and nothing to send it back, so it goes
		# straight into the same handler a real line arrives at. The *shape* is
		# dot-server's, which is what makes that possible.
		_on_chat(_offline.say(text))


## A chat line from dot-server. Already sanitised and already filtered.
func _on_chat(payload: Dictionary) -> void:
	ui.add_chat(payload)

	# The bubble over somebody's head is drawn from the same message the log is, rather
	# than from a second event. One path, so a bubble can never say something the log does
	# not — which is what a second path eventually produces.
	var occupant := world.occupant_for(int(payload.get("userid", 0)))

	if occupant != null:
		occupant.say(String(payload.get("text", "")), Time.get_ticks_msec())


func _on_roster_changed(occupant_id: int, present: bool) -> void:
	_roster_dirty = true

	var occupant := world.occupant_for(occupant_id)
	var who := occupant.display_name if occupant != null else "Somebody"

	if not _roster_ready:
		return

	ui.add_notice(
		"%s joined." % who if present else "%s left." % who,
		Color(0.55, 0.85, 0.60) if present else Color(0.85, 0.60, 0.55)
	)


func _on_disconnected(reason: String) -> void:
	input.enabled = false
	ui.set_status(
		"Disconnected: %s" % reason if reason != "" else "Disconnected.",
		Color(1.0, 0.55, 0.55)
	)
