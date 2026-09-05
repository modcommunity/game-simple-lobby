class_name RoomRequest
extends DotNetMessage

## Everything a client asks the authority for.
##
## Today that is one thing — "I have loaded, tell me about the room" — and it is still a
## message with a kind rather than a bare signal, because the next one (a name change, a
## seat, an emote) must not be a second registered type on one side only.
##
## [b]Nothing here carries state.[/b] A client sends what it *wants*; where it is standing
## is [RoomNetCommand]'s, and even that is an intent rather than a position. A client that
## could send a position could send any position.

const NAME := &"room.request"

const KIND_BITS := 4
const MAX_BODY := 512

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray = PackedByteArray()) -> RoomRequest:
	var request := RoomRequest.new()
	request.kind = p_kind
	request.body = p_body
	return request


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= RoomEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown ask %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "RoomRequest(%d, %d bytes)" % [kind, body.size()]
