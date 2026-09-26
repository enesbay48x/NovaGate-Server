import sys, re

def should_be_newline(next_part: bytes) -> bool:
    if not next_part:
        return True
    first = next_part[0:1]
    if first in (b"\t", b"@"):
        return True
    if first == b"}":
        return True
    if first == b" ":
        return False
    if first in b"0123456789+-*/%=!<>|&.,;:?\"'[]":
        return True
    head = next_part[:10]
    lower = head.lower()
    kw = (
        lower.startswith(b"tool") or lower.startswith(b"extends") or
        lower.startswith(b"class") or lower.startswith(b"enum") or
        lower.startswith(b"signal") or lower.startswith(b"const") or
        lower.startswith(b"var") or lower.startswith(b"onready") or
        lower.startswith(b"export") or lower.startswith(b"func") or
        lower.startswith(b"if") or lower.startswith(b"elif") or
        lower.startswith(b"else") or lower.startswith(b"for") or
        lower.startswith(b"while") or lower.startswith(b"match") or
        lower.startswith(b"return") or lower.startswith(b"break") or
        lower.startswith(b"continue") or lower.startswith(b"pass") or
        lower.startswith(b"struct") or lower.startswith(b"typedef") or
        lower.startswith(b"preload") or lower.startswith(b"load") or
        lower.startswith(b"print") or lower.startswith(b"push") or
        lower.startswith(b"assert") or lower.startswith(b"emit") or
        lower.startswith(b"call") or lower.startswith(b"get_") or
        lower.startswith(b"add_") or lower.startswith(b"remove") or
        lower.startswith(b"set_") or lower.startswith(b"queue") or
        lower.startswith(b"has") or lower.startswith(b"is") or
        lower.startswith(b"not") or lower.startswith(b"and") or
        lower.startswith(b"or") or lower.startswith(b"as") or
        lower.startswith(b"true") or lower.startswith(b"false") or
        lower.startswith(b"null") or lower.startswith(b"static") or
        lower.startswith(b"remote") or lower.startswith(b"master") or
        lower.startswith(b"slave")
    )
    return kw

cases = [
    ("String = \"\"  -> # comment", b"# A rutbesi"),
    ("String = \"\"  -> var _a_rank", b"var _a_rank_status_message"),
    ("const space    -> ORMAL_LASER", b"ORMAL_LASER_SLOT_CAP"),
    ("exte           -> nds Co", b"nds Co"),
    ("node          -> _path:", b"_path:"),
    ("\"../..\")     -> @export", b"@export var player_path"),
]
for desc, nxt in cases:
    print(desc, "should_be_newline =", should_be_newline(nxt), repr(nxt[:24]))
