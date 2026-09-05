class_name RoomUi
extends Control

## The chat log, the entry, the roster and the join/leave feed.
##
## The three things the lobby is actually for, and the only part of this game a person
## looks at for longer than a second. Built out of dot-ui's widgets — [DotTableView] for
## the roster, [DotFeedView] for the notifications — because they already solve line
## expiry, fading, column widths and header colours, and a second implementation of any of
## those would drift.
##
## [b]Chat text arrives from dot-server, not from this game's netcode.[/b]
## [DotChatManager] has already sanitised it — control characters, zero-width characters
## and bidirectional overrides stripped, whitespace collapsed, length truncated — and
## filtered admin chat server-side. Nothing here re-implements any of that, and nothing
## here may: asking a client to hide messages it is not entitled to see is not a control.

const CHANNEL := "room.ui"

## Somebody pressed Enter with text in the box.
signal chat_submitted(text: String)

## The entry took or lost the keyboard. [RoomInput] is disabled while it holds it.
signal typing_changed(typing: bool)

## Lines kept in the chat log.
##
## Bounded because every one of them is a [Label] in a container: a chat room left open
## overnight is otherwise a few hundred thousand nodes.
const MAX_CHAT_LINES := 120

## Layout, in pixels. Named because three of them are used twice and a magic number used
## twice is two numbers that will eventually differ.
const MARGIN := 16.0
const ROSTER_WIDTH := 244.0
const CHAT_WIDTH := 460.0
const CHAT_HEIGHT := 212.0

var _log: VBoxContainer = null
var _scroll: ScrollContainer = null
var _entry: LineEdit = null
var _roster: DotTableView = null
var _roster_count: Label = null
var _feed: DotFeedView = null
var _status: Label = null

## Whether the log was scrolled to the bottom before the newest line was added.
##
## Read *before* appending and applied after: somebody reading back through the log must
## not be yanked to the bottom every time anybody speaks, and somebody who is at the
## bottom must not have to scroll for every line. There is no third behaviour that is
## right for both.
var _was_at_bottom: bool = true


func _ready() -> void:
	# [b]`_and_offsets_`, not `set_anchors_preset`.[/b] The anchors alone describe how a
	# rectangle should follow its parent and change nothing until something resizes it, so
	# a control built in code and never touched again keeps the zero size it was created
	# with. Every child then lays out inside nothing and the whole interface is invisible
	# while being, by every property, correctly configured.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _build() -> void:
	_feed = DotFeedView.new()
	_feed.name = "Feed"
	_feed.max_lines = 6
	_feed.lifetime_sec = 7.0
	_feed.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_feed.position = Vector2(MARGIN, MARGIN)
	_feed.size = Vector2(420, 140)
	add_child(_feed)

	# --- the roster, top right ---
	var roster_box := VBoxContainer.new()
	roster_box.name = "Roster"
	# Pinned to the top-right corner by anchors *and* offsets, so it follows a resize
	# rather than sitting where the window happened to be when it was built. A browser tab
	# is resized constantly and a phone rotating is a resize.
	roster_box.anchor_left = 1.0
	roster_box.anchor_right = 1.0
	roster_box.offset_left = -(ROSTER_WIDTH + MARGIN)
	roster_box.offset_right = -MARGIN
	roster_box.offset_top = MARGIN
	roster_box.offset_bottom = MARGIN
	roster_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	roster_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(roster_box)

	_roster_count = Label.new()
	_roster_count.text = "In the room"
	_roster_count.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	roster_box.add_child(_roster_count)

	_roster = DotTableView.new()
	_roster.name = "Table"
	_roster.show_header = false
	_roster.max_rows = RoomContent.MAX_OCCUPANTS
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# `width` is a stretch ratio, not pixels — the name takes the slack and the duration
	# does not. Keys are [StringName]s because that is what [DotTableView] looks rows up
	# with, and a String key would find nothing and render a table of empty cells.
	var columns: Array[Dictionary] = [
		{"key": &"name", "width": 3.0},
		{"key": &"here", "align": HORIZONTAL_ALIGNMENT_RIGHT},
	]
	_roster.set_columns(columns)
	roster_box.add_child(_roster)

	# --- the chat log and entry, bottom left ---
	var chat_box := VBoxContainer.new()
	chat_box.name = "Chat"
	chat_box.anchor_top = 1.0
	chat_box.anchor_bottom = 1.0
	chat_box.offset_left = MARGIN
	chat_box.offset_right = MARGIN + CHAT_WIDTH
	chat_box.offset_top = -(CHAT_HEIGHT + MARGIN)
	chat_box.offset_bottom = -MARGIN
	chat_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(chat_box)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chat_box.add_child(_scroll)

	_log = VBoxContainer.new()
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_log)

	_entry = LineEdit.new()
	_entry.placeholder_text = "Press Enter to talk"
	_entry.max_length = 240
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Off until Enter is pressed. A text box that always had the keyboard would eat W, A,
	# S and D — which is the whole movement scheme — and the player would have no way of
	# telling why walking had stopped working.
	_entry.editable = false
	_entry.text_submitted.connect(_on_submitted)
	_entry.focus_entered.connect(func() -> void: typing_changed.emit(true))
	_entry.focus_exited.connect(_stop_typing)
	chat_box.add_child(_entry)

	_status = Label.new()
	_status.name = "Status"
	# Centred across the whole width rather than a fixed box offset from the middle: a
	# fixed one clips its own text on a narrow window, which is every phone.
	_status.anchor_right = 1.0
	_status.offset_top = MARGIN
	_status.offset_bottom = MARGIN + 24.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status)


# --- Typing ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return

	var key := event as InputEventKey

	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		start_typing()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE and is_typing():
		_entry.text = ""
		_stop_typing()
		get_viewport().set_input_as_handled()


## Gives the entry the keyboard.
func start_typing() -> void:
	if _entry == null or _entry.editable:
		return

	_entry.editable = true
	_entry.grab_focus()
	typing_changed.emit(true)


func _stop_typing() -> void:
	if _entry == null:
		return

	_entry.editable = false
	_entry.release_focus()
	typing_changed.emit(false)


func is_typing() -> bool:
	return _entry != null and _entry.editable


func _on_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	_entry.text = ""

	# The entry stays open after a line is sent, so a conversation is a conversation
	# rather than a sequence of Enter presses. Escape, or submitting nothing, closes it.
	if trimmed == "":
		_stop_typing()
		return

	chat_submitted.emit(trimmed)


# --- Content ---------------------------------------------------------------

## Adds a chat line.
##
## [param payload] is dot-server's, verbatim: `kind`, `userid`, `name`, `text`, `admin`.
func add_chat(payload: Dictionary) -> void:
	var speaker := String(payload.get("name", ""))
	var text := String(payload.get("text", ""))
	var kind := String(payload.get("kind", "all"))
	var userid := int(payload.get("userid", 0))

	if text == "":
		return

	var line := Label.new()
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if speaker == "":
		# A system message: a kick, a game change, a vote result. Distinguished by
		# having no speaker rather than by a flag, because that is how dot-server sends
		# one and inventing a second signal for it would be a second thing to keep true.
		line.text = text
		line.add_theme_color_override("font_color", Color(0.65, 0.72, 0.80))
	else:
		line.text = "%s: %s" % [speaker, text]
		line.add_theme_color_override(
			"font_color",
			Color(1.0, 0.82, 0.35) if bool(payload.get("admin", false))
			else RoomContent.colour_for(userid).lightened(0.25)
		)

	if kind == "team":
		line.text = "(team) " + line.text

	_append(line)


## Adds a line nobody said: joins, leaves, connection state.
func add_notice(text: String, colour: Color = Color(0.60, 0.68, 0.78)) -> void:
	var line := Label.new()
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.text = text
	line.add_theme_color_override("font_color", colour)
	_append(line)

	if _feed != null:
		_feed.add_text(text, colour)


func _append(line: Label) -> void:
	if _log == null:
		return

	_was_at_bottom = _at_bottom()
	_log.add_child(line)

	while _log.get_child_count() > MAX_CHAT_LINES:
		var oldest := _log.get_child(0)
		_log.remove_child(oldest)
		oldest.queue_free()

	if _was_at_bottom:
		# Deferred by two frames: the container has not laid the new label out yet, so
		# scrolling now scrolls to the old maximum and lands one line short. One frame is
		# enough for the label and not always for the wrap.
		_scroll_to_bottom.call_deferred()


func _scroll_to_bottom() -> void:
	await get_tree().process_frame

	if _scroll != null and is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _at_bottom() -> bool:
	if _scroll == null:
		return true

	var bar := _scroll.get_v_scroll_bar()
	return _scroll.scroll_vertical >= int(bar.max_value - bar.page) - 4


## Redraws the roster from the world.
##
## Called on a change rather than every frame: the "here for" column only changes once a
## second and rebuilding a table of sixty-four labels at 144 Hz would be the most
## expensive thing in the game.
func set_roster(occupants: Array[RoomOccupant], local_id: int) -> void:
	if _roster == null:
		return

	var now := int(Time.get_unix_time_from_system())
	var rows: Array[Dictionary] = []

	for occupant in occupants:
		rows.append({
			&"name": occupant.display_name,
			&"here": _duration(maxi(0, now - occupant.joined_at)),
			"highlight": occupant.id == local_id,
			"colour": occupant.colour().lightened(0.2),
		})

	_roster.set_rows(rows)
	_roster_count.text = "In the room — %d" % occupants.size()


static func _duration(seconds: int) -> String:
	if seconds < 60:
		return "%ds" % seconds
	if seconds < 3600:
		return "%dm" % (seconds / 60)
	return "%dh" % (seconds / 3600)


## The banner across the top: connecting, downloading, a refusal.
##
## Empty hides it. A blank banner and a missing one look the same and behave differently
## the moment anything is laid out beside it.
func set_status(text: String, colour: Color = Color(0.85, 0.88, 0.92)) -> void:
	if _status == null:
		return

	_status.text = text
	_status.visible = text != ""
	_status.add_theme_color_override("font_color", colour)
