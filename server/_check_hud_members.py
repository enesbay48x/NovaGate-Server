"""Verify that every GlobalState member the server-state HUD reads exists.

WHY A SCRIPT AND NOT JUST A PARSE
----------------------------------
`GlobalState` is an autoload, so GDScript resolves `GlobalState.x` at RUNTIME,
not at parse time. A typo therefore parses cleanly and only fails when the HUD
is instantiated - i.e. in front of a player. This checks the member names
statically so that class of typo is caught here instead.

Usage:  python _check_hud_members.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GLOBAL_STATE = os.path.join(ROOT, "scripts", "GlobalState.gd")
HUD = os.path.join(ROOT, "scripts", "server_state_hud.gd")

# Members that must exist in GlobalState for the HUD to render. Anything not in
# this set is fine to reference; these are the ones the HUD depends on.
REQUIRED = [
    # progression
    "level", "xp", "honor",
    # economy
    "bitcoin", "platinum", "gold",
    # vitals (the "-1 means unknown" sentinels)
    "server_health", "server_max_health",
    "server_shield", "server_max_shield",
    # world
    "server_map", "start_map", "server_has_position",
    "server_pos_x", "server_pos_y", "rank_company_count",
    # ship / equipment / combat
    "active_ship_id", "ship_name", "selected_config",
    "server_equipment_lasers", "server_laser_damage",
    "server_speed_bonus", "server_ammo",
]

# Members the HUD must NOT write to. The HUD is a view; a write would make it a
# second source of truth, which is the exact failure this panel exists to avoid.
FORBIDDEN_WRITES = set(REQUIRED)


def declared_members(text: str) -> set:
    """Top-level `var <name>` declarations in GlobalState."""
    names = set()
    pattern = re.compile(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", re.MULTILINE)
    for match in pattern.finditer(text):
        names.add(match.group(1))
    return names


def hud_reads(text: str) -> set:
    """`GlobalState.<member>` references in the HUD."""
    return set(re.findall(r"GlobalState\.([A-Za-z_][A-Za-z0-9_]*)", text))


def main() -> int:
    with open(GLOBAL_STATE, encoding="utf-8") as fh:
        gs_text = fh.read()
    with open(HUD, encoding="utf-8") as fh:
        hud_text = fh.read()

    available = declared_members(gs_text)
    used = hud_reads(hud_text)
    missing = sorted(used - available)

    print("GlobalState declares %d members" % len(available))
    print("HUD references %d members" % len(used))
    if missing:
        print("MISSING (would fail at runtime): %s" % ", ".join(missing))
        return 1
    print("OK  every GlobalState member the HUD reads exists")

    # The HUD must not assign to GlobalState at all.
    writes = re.findall(r"GlobalState\.[A-Za-z_][A-Za-z0-9_]*\s*(?:=|\+=|-=|\*=|/=)(?!=)",
                       hud_text)
    if writes:
        print("FAIL the HUD writes to GlobalState: %s" % ", ".join(writes))
        return 1
    print("OK  the HUD performs zero writes to GlobalState (it is a pure view)")

    # And it must not keep its own gameplay variables.
    own_state = re.findall(r"^var\s+_(?!labels)\w+\s*:", hud_text, re.MULTILINE)
    if own_state:
        print("FAIL the HUD declares its own state: %s" % ", ".join(own_state))
        return 1
    print("OK  the HUD keeps no parallel gameplay state")

    required_absent = sorted(set(REQUIRED) - available)
    if required_absent:
        print("NOTE: these expected members are absent from GlobalState: %s"
              % ", ".join(required_absent))
        return 1
    print("OK  all %d expected members are declared" % len(REQUIRED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
