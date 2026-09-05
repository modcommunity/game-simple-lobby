class_name RoomOccupant
extends RefCounted

## One person in the room.
##
## Deliberately not a [Node]. The state has to be snapshotted, rewound and replayed
## several times a second by [DotNetPredictor], and a state that lives on a [Node2D]
## cannot be any of those without touching the scene tree — dot-fps-controller and dot-2d
## both split it for that reason and this follows them.
##
## [b]The id is the session id, never the peer id.[/b] A peer id is reassigned the moment
## somebody reconnects, so anything keyed by one hands the next player to join whatever
## the last one had: their name, their colour, their position in the roster.

## Session id. Stable for as long as this person is connected, and the key for everything.
var id: int = 0

## What everybody else sees above them. Sanitised by the server before it gets here.
var display_name: String = ""

## Where they are and how they are moving.
var state: Dot2DState = null

## The newest command the authority has for them, and what a predicting client replays.
##
## Held here rather than passed around because it belongs to the person: it survives a
## tick on which no input arrived, which is what stops a player stopping dead every time
## a packet is late.
var last_command: Dot2DCommand = null

## Whether this is somebody a client is predicting, i.e. themselves. Client side only.
var is_local: bool = false

## Set by [RoomBridge] so the world can reach the replicating half. Null on a bot and on
## anything the netcode has not registered yet.
var net: Object = null

## Unix seconds this person entered the room. Shown in the roster, and the only reason a
## lobby needs a clock at all.
var joined_at: int = 0

## Newest chat line, and the tick it arrived on.
##
## [b]Not replicated.[/b] Chat is dot-server's — routed, sanitised, flood-limited and
## permission-filtered by [DotChatManager], which every client already receives through
## [signal DotClientLink.chat_received]. A second copy on the wire would be a second set
## of rules to keep in step, and the one that skipped the filter would be the one that
## leaked admin chat. What this holds is the bubble a client draws from what it was
## already told.
var bubble_text: String = ""
var bubble_until_ms: int = 0


static func create(p_id: int, p_name: String, at: Vector2) -> RoomOccupant:
	var occupant := RoomOccupant.new()
	occupant.id = p_id
	occupant.display_name = p_name
	occupant.state = Dot2DState.at(at, RoomContent.OCCUPANT_RADIUS)
	occupant.state.mass = 1.0
	occupant.last_command = Dot2DCommand.new()
	occupant.joined_at = int(Time.get_unix_time_from_system())
	return occupant


func position() -> Vector2:
	return state.position


func colour() -> Color:
	return RoomContent.colour_for(id)


## Shows a chat bubble for a while.
##
## The duration scales with the length of the line so that a long message is readable and
## a short one does not linger, and it is clamped so that neither end of that is abusable:
## the text arrives from another player.
func say(text: String, now_ms: int) -> void:
	bubble_text = text
	bubble_until_ms = now_ms + clampi(1500 + text.length() * 60, 1500, 7000)


func has_bubble(now_ms: int) -> bool:
	return bubble_text != "" and now_ms < bubble_until_ms


func describe() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"position": state.position,
		"speed": state.speed(),
		"local": is_local,
	}


func _to_string() -> String:
	return "RoomOccupant(%d %s at %.0f,%.0f)" % [
		id, display_name, state.position.x, state.position.y
	]
