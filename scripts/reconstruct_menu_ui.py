import sys, os

base = r"C:\Users\Pc\Downloads\çalışanzip\scripts"
corrupted = os.path.join(base, "menu_ui.gd")
restored = os.path.join(base, "menu_ui_restored.gd")

with open(corrupted, "rb") as f:
    data = f.read()

fragments = data.split(b"\r\n")
print(f"Total CRLF-separated parts: {len(fragments)}", file=sys.stderr)

# Patterns that suggest a real line start (not continuation after removed 'n'/'N')
real_start_prefixes = (
    b"@", b"#", b"var ", b"func ", b"if ", b"elif ", b"else",
    b"for ", b"while ", b"const ", b"signal ", b"enum ", b"struct ",
    b"tool ", b"class_name", b"extends ", b"onready ", b"export ",
    b"return ", b"break", b"continue", b"pass", b"match ", b"case ",
    b"preload(", b"load(", b"print(", b"print_rich(", b"push_warning(",
    b"push_error(", b"assert(", b"yield(", b"await ",
    b"get_node(", b"get_tree(", b"get_parent(", b"get_node_or_null(",
    b"add_child(", b"remove_child(", b"queue_free", b"emit_signal(",
    b"call_deferred(", b"connect(", b"has(", b"is ", b"not ", b"and ",
    b"or ", b"as ", b"true", b"false", b"null",
    b"func _", b"func __",
    b"\t", b"    ",
    b"\tvar", b"\tfunc", b"\tif",
    b"\treturn", b"\tfor", b"\twhile", b"\tif", b"\telif", b"\telse",
    b"\tconst", b"\tsignal", b"\tenum", b"\tstruct", b"\ttool",
    b"\ttry", b"\texcept", b"\tfinally", b"\twith", b"\tfrom",
    b"\tclass", b"\tdef",
)

def is_real_start(part):
    if not part:
        return True
    if part[:1] in (b"@", b"#"):
        return True
    for pat in real_start_prefixes:
        if part.startswith(pat):
            return True
    return False

restored_parts = []
current = fragments[0]
real_lines = 0
replaced_n = 0

for i in range(1, len(fragments)):
    nxt = fragments[i]
    if is_real_start(nxt):
        restored_parts.append(current)
        current = nxt
        real_lines += 1
    else:
        if nxt and nxt[:1].isalpha() and nxt[:1].isupper():
            current = current + b"N" + nxt
        else:
            current = current + b"n" + nxt
        replaced_n += 1

if current:
    restored_parts.append(current)

result = b"\r\n".join(restored_parts)

crlf_count = result.count(b"\r\n")
print(f"\nReal line breaks: {real_lines}", file=sys.stderr)
print(f"Restored n/N characters: {replaced_n}", file=sys.stderr)
print(f"CRLF in restored: {crlf_count}", file=sys.stderr)
print(f"Restored file size: {len(result)} bytes", file=sys.stderr)

with open(restored, "wb") as f:
    f.write(result)

print(f"\nWritten to: {restored}", file=sys.stderr)
print(f"\nFirst 1000 chars of restored file:", file=sys.stderr)
print(result[:1000].decode("utf-8", errors="replace"), file=sys.stderr)
