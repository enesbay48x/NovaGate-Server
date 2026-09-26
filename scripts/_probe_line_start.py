import sys
sys.path.insert(0, r"C:\Users\Pc\Downloads\çalışanzip\scripts")
from _reconstruct_menu_ui import is_line_start

tests = [
    ("ends with string, next is comment", b'String = ""', b"# A rutbesi"),
    ("ends with string, next is var", b'String = ""', b"var _a_rank_status_message"),
    ("ends with const space, next is NORMAL", b"const ", b"ORMAL_LASER_SLOT_CAP"),
    ("ends with letter, next is 'n'", b"exte", b"nds Co"),
]
for desc, cur, nxt in tests:
    print(desc, "->", is_line_start(nxt), repr(cur[-8:]), repr(nxt[:20]))
