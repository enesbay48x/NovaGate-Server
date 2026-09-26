import re, sys

SRC = r"C:\Users\Pc\Downloads\çalışanzip\scripts\menu_ui_restored_preparse.gd"
DST = r"C:\Users\Pc\Downloads\çalışanzip\scripts\menu_ui_restored.gd"
DRY = True

with open(SRC, "r", encoding="utf-8") as f:
    s = f.read()

before = s

# ----------------------------------------------------------------------
# 1) Turn stray literal "n" into newlines at GDScript line-start points.
#    Heuristic: a lone ASCII "n" surrounded by non-newline chars, where the
#    following non-space token begins a new line/keyword.
# ----------------------------------------------------------------------
kw_start = r"""
(?:tool|extends|class[_\s]?name|enum|signal|const|var|onready|
  export|group|static|remote|master|slave|pc|annotation|warning|
  func|if|elif|else|for|while|match|case|default|
  return|break|continue|pass|struct|typedef|preload|load|
  yield|await|print|print_rich|push_warning|push_error|assert|
  emit|call|get_node|set_|add_child|remove_child|add_to_group|
  remove_from_group|queue_free|has|is|not|and|or|as|
  true|false|null)
"""
kw_re = re.compile(r"^" + kw_start, re.VERBOSE | re.IGNORECASE)

def next_nonspace_after(text, idx):
    j = idx
    while j < len(text) and text[j] in " \t\r\n":
        j += 1
    return j

def stray_n_to_newline(m):
    i = m.start()
    j = i + 1  # position right after the 'n'
    k = next_nonspace_after(s, j)
    if k >= len(s):
        return "n"
    nxt = s[k:]
    if nxt.startswith("#"):
        return "\n"
    if nxt.startswith("@"):
        return "\n"
    m2 = re.match(r"[A-Za-z]", nxt)
    if m2:
        prefix = nxt[:10].lower()
        if kw_re.match(prefix):
            return "\n"
    # numeric or collection start after space
    if re.match(r"\s*[\[\{\"]", nxt):
        return "\n"
    return "n"

s = re.sub(r"(?<=[^\n])n(?=[^\n])", stray_n_to_newline, s)

# collapse accidental multi-n sequences left from mistaken merges
s = s.replace("nn", "\n").replace("n\n", "\n").replace("\nn", "\n")
s = re.sub(r"\n{3,}", "\n\n", s)

# ----------------------------------------------------------------------
# 2) Fix split identifiers created by earlier corruption.
# ----------------------------------------------------------------------
id_map = {
    "Dictio\nary": "Dictionary",
    "Stri\nng": "String",
    "Array\n[": "Array[",
    "INputEventKey": "InputEventKey",
    "INputEventMouse": "InputEventMouse",
    "Vecto\nr2": "Vector2",
    "Rect2\n": "Rect2",
    "ColorR\next": "ColorRect",
    "Butto\nn": "Button",
    "TextureRect\n": "TextureRect",
    "GridContainer\n": "GridContainer",
    "VBoxContainer\n": "VBoxContainer",
    "RichTextLabel\n": "RichTextLabel",
    "FileAccess\n": "FileAccess",
    "DirAccess\n": "DirAccess",
    "JSON\n": "JSON",
    "PackedScene\n": "PackedScene",
    "NodePath\n": "NodePath",
    "StringName\n": "StringName",
    "Callable\n": "Callable",
    "Horizontal\nAlignment": "HorizontalAlignment",
    "Horizontal\n": "Horizontal",
    "Vertical\n": "Vertical",
    "Dimension\n": "Dimension",
}
for bad, good in id_map.items():
    s = s.replace(bad, good)

# generic letter-newline-letter merge when it forms a valid identifier
s = re.sub(r"(?<=[A-Za-z])\n(?=[A-Za-z])", lambda m: (m.group(0)[0]+m.group(0)[2]) if (m.group(0)[0]+m.group(0)[2]).isidentifier() else m.group(0), s)

# ----------------------------------------------------------------------
# 3) Godot 4.7.2 compatibility fixes
# ----------------------------------------------------------------------
n_size_fixed = len(re.findall(r"\bSIZE_FIXED\b", s))
s = re.sub(r"\bSIZE_FIXED\b", "SIZE_SHRINK_END", s)

n_vert = len(re.findall(r"\bControl\.VERTICAL_ALIGNMENT_CENTER\b", s))
n_vert += len(re.findall(r"\bcontrol\.VERTICAL_ALIGNMENT_CENTER\b", s))
s = re.sub(r"\bControl\.VERTICAL_ALIGNMENT_CENTER\b", "VERTICAL_ALIGNMENT_CENTER", s)
s = re.sub(r"\bcontrol\.VERTICAL_ALIGNMENT_CENTER\b", "VERTICAL_ALIGNMENT_CENTER", s)

# Qualified color refs: attach NovaGateUITheme prefix to bare PRIMARY/GREEN/DIM
# when used like a color value (after =, +, comma, paren, etc.)
for name in ["PRIMARY", "GREEN", "DIM"]:
    pat = re.compile(
        r"(?P<pre>\s*[,+=(\[\:])\s*\b" + re.escape(name) + r"\b"
    )
    def qual(m, name=name):
        return re.sub(r"\s+", " ", m.group(0)).strip()
    s = re.sub(
        r"(\s*[,+=(\[\:])\s*\b" + re.escape(name) + r"\b",
        lambda m: m.group(1) + " NovaGateUITheme." + name,
        s)
    )

counts = {
    "size_fixed_found": n_size_fixed,
    "vert_member_found": n_vert,
    "changed": s != before,
    "len_before": len(before),
    "len_after": len(s),
}

print("CHANGED", counts["changed"])
print("len_before", counts["len_before"], "len_after", counts["len_after"])
print("size_fixed_found", counts["size_fixed_found"])
print("vert_member_found", counts["vert_member_found"])

if DRY:
    sample = [ln for ln in s.splitlines() if ("NovaGateUITheme.PRIMARY" in ln or "NovaGateUITheme.GREEN" in ln or "NovaGateUITheme.DIM" in ln or "SIZE_SHRINK_END" in ln or "VERTICAL_ALIGNMENT_CENTER" in ln)]
    print("SAMPLES", len(sample), file=sys.stderr)
    for ln in sample[:25]:
        print("SAMPLE>", ln, file=sys.stderr)
    print("DRY_RUN_DONE", file=sys.stderr)
    sys.exit(0)

with open(DST, "w", encoding="utf-8") as f:
    f.write(s)
print("WROTE", DST, file=sys.stderr)
