class_name RoomNetCommand
extends DotNetInput

## One tick of a person's intent, on the wire.
##
## [b]This is the only thing a client is allowed to send about itself.[/b] Clients send
## inputs, never state — a client that could send a position could send any position, and
## dot-net's whole security model rests on the distinction. In a lobby that matters less
## than in a shooter and it is still not optional: walking through somebody is the
## cheapest way to make a chat room unpleasant.
##
## A thin wrapper around [Dot2DCommand] rather than a set of fields, because
## [Dot2DCommand] already knows how to quantise itself through a duck-typed [Variant]
## writer. dot-2d cannot name a dot-net class — a script that mentions a missing
## [code]class_name[/code] fails to parse — so the composition happens here and the
## quantisation decisions stay in the addon that owns them.

## Largest pointer distance accepted, in world units. Also the wire's range, so both ends
## must agree; a constant rather than a field for that reason.
##
## A room's diagonal, near enough. A drag cannot mean anything further than the room is.
const MAX_REACH := 1200.0

var command: Dot2DCommand = Dot2DCommand.new()


func _write(writer: DotNetWriter) -> void:
	command.write(writer, MAX_REACH)


func _read(reader: DotNetReader) -> void:
	command = Dot2DCommand.new()
	command.read(reader, MAX_REACH)


## Clamps what a client could exaggerate.
##
## Not redundant with quantisation: quantisation bounds each field on its own and cannot
## bound the relationship between them. A move vector of (1, 1) is two legal components
## and a length of 1.41 — which is a person walking forty percent faster than everybody
## else, and the one cheat a server that trusts its clients cannot detect afterwards.
func _sanitise() -> void:
	command.sanitise(MAX_REACH)


## Whether two inputs are identical, so somebody standing still costs less.
##
## Which in a lobby is most people most of the time, and is the reason a chat room full
## of idle players costs almost nothing.
func _equals(other: DotNetInput) -> bool:
	var them := other as RoomNetCommand
	return them != null and command.equals(them.command)


static func estimated_bits() -> int:
	return Dot2DCommand.estimated_bits()


func describe() -> Dictionary:
	return {"tick": tick, "command": command.describe()}
