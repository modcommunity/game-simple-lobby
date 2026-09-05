class_name RoomEvents
extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in one place, in pairs, because they have to be exact inverses
## and nothing can check that for you — `examples/headless_net.tscn` round-trips every
## one of them for that reason.
##
## [b]Chat is not here.[/b] dot-server already routes, sanitises, flood-limits and
## permission-filters it, and every client receives it through
## [signal DotClientLink.chat_received]. A second chat path would be a second set of
## rules to keep in step, and the one that skipped the filter would be the one that
## leaked admin chat to everybody. What travels here is who is in the room and where
## they are standing.

## What the authority sends.
enum Kind {
	## Who you are, what tick it is, how big the room is. The first thing a client is told.
	HELLO,
	## Somebody is in the room: their id, their name, and where they entered.
	##
	## Sent once per person on join, and once per person already here when *you* join.
	## One kind for both, because a client that had to distinguish "the roster" from "a
	## join" would need two handlers that must agree, and they would not.
	JOIN,
	## Somebody left.
	LEAVE,
	## An occupant became a replicated entity and should be mirrored.
	SPAWN,
	## An occupant's entity is gone.
	DESPAWN,
	## The roster has been sent in full; everything after this is live.
	##
	## Not decoration: a client that drew its roster as the JOINs arrived would show the
	## room filling up one person at a time on every connect, and would have no moment at
	## which it could say "you are in".
	ROSTER_END,
}

## What a client asks for.
enum Ask {
	## I have loaded and have somewhere to put events. Tell me about the room.
	READY,
}

## Position range, matching [Dot2DNetSync] so that a position sent as an event and the
## same position sent in a snapshot quantise identically. Two grids for one coordinate is
## a person standing a pixel from where the server says they are, forever.
const POSITION_BITS := Dot2DNetSync.POSITION_BITS
const WORLD_EXTENT := Dot2DNetSync.WORLD_EXTENT

const NAME_BYTES := RoomContent.NAME_BYTES


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func _write_position(writer: DotNetWriter, at: Vector2) -> void:
	writer.write_vector2_range(at, -WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


static func _read_position(reader: DotNetReader) -> Vector2:
	return reader.read_vector2_range(-WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


# --- HELLO -----------------------------------------------------------------

## [param room_size] is sent even though [RoomContent] is a constant on both ends.
##
## Not redundancy for its own sake: the client checks it and refuses a server whose room
## is a different size, because that mismatch is otherwise silent. Every position would
## still decode, every id would still match, and everybody would simply be standing
## somewhere else — the single most confusing failure dot-2d-hungry found, reached from
## the same direction.
static func write_hello(
	occupant_id: int,
	peer_id: int,
	server_tick: int,
	tick_rate: int,
	room_size: Vector2
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_uint(tick_rate, 8)
	writer.write_float32(room_size.x)
	writer.write_float32(room_size.y)
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"occupant_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"tick": reader.read_uint(32),
		"tick_rate": reader.read_uint(8),
		"room_size": Vector2(reader.read_float32(), reader.read_float32()),
	}
	out["ok"] = reader.ok()
	return out


# --- JOIN / LEAVE ----------------------------------------------------------

static func write_join(
	occupant_id: int,
	display_name: String,
	at: Vector2,
	joined_at: int
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	writer.write_string(display_name, NAME_BYTES)
	_write_position(writer, at)
	# Unix seconds, so a client can say "here for 4 minutes" without the server sending
	# a duration that would be stale the moment it arrived.
	writer.write_uint(joined_at, 32)
	return writer.to_bytes()


static func read_join(reader: DotNetReader) -> Dictionary:
	var out := {
		"occupant_id": reader.read_varint(),
		"name": reader.read_string(NAME_BYTES),
		"position": _read_position(reader),
		"joined_at": reader.read_uint(32),
	}
	out["ok"] = reader.ok()
	return out


static func write_occupant(occupant_id: int) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	return writer.to_bytes()


static func read_occupant(reader: DotNetReader) -> int:
	return reader.read_varint()


# --- SPAWN / DESPAWN -------------------------------------------------------

## Ties a net id to an occupant, so a client knows whose the arriving state is.
##
## Sent reliably and before any snapshot mentioning it. A client that meets an entity it
## has not been told to spawn abandons the rest of that snapshot — it cannot skip a
## variable-length body without the declarations — so a late spawn costs every other
## entity in the same packet.
static func write_spawn(
	net_id: int,
	peer_id: int,
	occupant_id: int,
	at: Vector2
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(net_id)
	writer.write_varint(peer_id)
	writer.write_varint(occupant_id)
	_write_position(writer, at)
	return writer.to_bytes()


static func read_spawn(reader: DotNetReader) -> Dictionary:
	var out := {
		"net_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"occupant_id": reader.read_varint(),
		"position": _read_position(reader),
	}
	out["ok"] = reader.ok()
	return out


static func write_despawn(net_id: int) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(net_id)
	return writer.to_bytes()


static func read_despawn(reader: DotNetReader) -> int:
	return reader.read_varint()


static func write_empty() -> PackedByteArray:
	return PackedByteArray()
