extends Node

## The launcher: connect to a server, or stand in an empty room offline.
##
## [codeblock]
## godot --path .                                   # the launcher
## godot --path . -- --offline                      # nobody else, no server
## godot --path . -- --connect 127.0.0.1:27085      # straight in
## godot --headless --path . -- --seconds 3         # exit on its own, for a sweep
## [/codeblock]
##
## [b]This is the standalone application, not the game.[/b] The game is
## `scenes/room_client.tscn`, and in the deployment this exists for a generic client shell
## downloads the pack and instantiates that scene itself — no launcher involved. What this
## is for is running the room on its own: to look at it, to develop it, and to be the main
## scene of a web export that has no shell in front of it.
##
## In a browser the server comes from the query string (`?server=wss://host:port`), because
## a tab cannot listen and a person who followed a link has already chosen which room they
## are joining.

const DEFAULT_PORT := 27085

var _link: DotClientLink = null
var _client: RoomClient = null
var _root: Node = null
var _status: Label = null
var _address_entry: LineEdit = null
var _name_entry: LineEdit = null
var _panel: Control = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if _has_arg("--verbose") else DotLog.Level.INFO
	)

	_arm_exit_timer()

	_root = Node.new()
	_root.name = "Game"
	add_child(_root)

	_build_menu()

	if _has_arg("--offline"):
		_start_offline()
		return

	var address := _requested_address()

	if address != "":
		_connect_to(address)


func _has_arg(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()


func _arg_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""


## Where to connect, from the command line or from the page's query string.
##
## [b]The query string is how a browser player arrives.[/b] They followed a link that
## already named a server; asking them to type an address they were never shown is asking
## them to leave.
func _requested_address() -> String:
	var from_cli := _arg_value("--connect")

	if from_cli != "":
		return from_cli

	if not DotPlatform.is_web():
		return ""

	return DotWeb.query_param("server")


# --- The menu --------------------------------------------------------------

func _build_menu() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Menu"
	add_child(layer)

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_panel)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-180, -110)
	box.custom_minimum_size = Vector2(360, 0)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "a room"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	box.add_child(title)

	var blurb := Label.new()
	blurb.text = "A place to stand about in while you decide where to go."
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", Color(0.66, 0.71, 0.78))
	box.add_child(blurb)

	box.add_child(_spacer(18))

	_name_entry = LineEdit.new()
	_name_entry.placeholder_text = "Your name"
	_name_entry.text = "Guest %d" % (randi() % 900 + 100)
	_name_entry.max_length = RoomContent.NAME_BYTES
	box.add_child(_name_entry)

	_address_entry = LineEdit.new()
	_address_entry.placeholder_text = "host:port"
	_address_entry.text = "127.0.0.1:%d" % DEFAULT_PORT
	box.add_child(_address_entry)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(func() -> void: _connect_to(_address_entry.text))
	box.add_child(join)

	# [b]No Host button.[/b] A browser tab cannot listen, and offering a control that
	# fails on the platform this game exists for is worse than not offering it. Offline is
	# offered instead, and it says what it is.
	var offline := Button.new()
	offline.text = "Stand in an empty room"
	offline.pressed.connect(_start_offline)
	box.add_child(offline)

	if DotPlatform.is_web():
		var note := Label.new()
		note.text = "A browser tab cannot host. Follow a link to somebody's room."
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
		box.add_child(note)

	box.add_child(_spacer(10))

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	# The join button is what a keyboard lands on. Grabbed after the node is in the tree:
	# focusing one that is not yet there is a menu that opens with nothing focused —
	# unusable with a gamepad and invisible with a mouse. game-arena shipped that.
	join.grab_focus.call_deferred()


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


func _set_menu_visible(shown: bool) -> void:
	if _panel != null:
		_panel.visible = shown


# --- Starting --------------------------------------------------------------

func _start_offline() -> void:
	_set_menu_visible(false)
	_spawn_client(null)


func _connect_to(address: String) -> void:
	var target := address.strip_edges()

	if target == "":
		_status.text = "Type an address first."
		return

	if not target.contains(":") and not target.begins_with("ws"):
		target = "%s:%d" % [target, DEFAULT_PORT]

	_status.text = "Connecting to %s…" % target

	_link = DotClientLink.new()
	# "Server", because Godot routes an RPC by the receiver's node path relative to its
	# MultiplayerAPI root and the server's node is called that. The name is the routing.
	_link.name = "Server"
	_link.player_name = _name_entry.text.strip_edges()
	_root.add_child(_link)

	_link.spawned.connect(_on_spawned)
	_link.disconnected.connect(_on_disconnected)
	_link.phase_changed.connect(func(_phase: int, text: String) -> void:
		_status.text = text
	)

	var connecting: DotResult = await _link.connect_to_server(target)

	if not connecting.ok:
		_status.text = "Could not connect: %s" % str(connecting.error)
		_link.queue_free()
		_link = null


func _on_spawned() -> void:
	_set_menu_visible(false)
	_spawn_client(_link)


## Builds the game the way a client shell would.
##
## Through the scene rather than the class, and with the link assigned before it enters
## the tree, because that is exactly what a shell does with a downloaded pack — and a path
## only the launcher takes is a path the deployment never runs.
func _spawn_client(link: DotClientLink) -> void:
	if _client != null and is_instance_valid(_client):
		return

	var packed: Variant = load("res://scenes/room_client.tscn")
	_client = (packed as PackedScene).instantiate() as RoomClient
	_client.link = link
	_root.add_child(_client)


func _on_disconnected(reason: String) -> void:
	if _client != null and is_instance_valid(_client):
		_client.queue_free()
		_client = null

	_set_menu_visible(true)
	_status.text = "Disconnected: %s" % (reason if reason != "" else "no reason given")


## Runs for `--seconds N` and then exits 0. Zero, the default, means forever.
##
## This scene is interactive: it waits for a person, so a blanket "run every example"
## sweep stalls here and the scene is therefore opened by nothing. That is the state a
## load-time regression hides in — a renamed node or a moved resource breaks it and no
## suite in the repository notices. Bounding it is what makes it sweepable, the same
## way dot-auth's issuer example is.
##
## Not a self-test: reaching the timeout only proves the scene loaded and ran frames.
## It exits 0 for exactly that claim and no larger one.
func _arm_exit_timer() -> void:
	var argv := OS.get_cmdline_user_args()
	var at := argv.find("--seconds")
	if at < 0 or at + 1 >= argv.size():
		return

	var seconds := maxf(0.0, argv[at + 1].to_float())
	if seconds <= 0.0:
		return

	print("Exiting in %.1f seconds (--seconds)." % seconds)
	await get_tree().create_timer(seconds).timeout
	print("--seconds elapsed; exiting.")
	get_tree().quit(0)
