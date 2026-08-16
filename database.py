import os
import psycopg2
from psycopg2.extras import RealDictCursor

DATABASE_URL = os.getenv("DATABASE_URL")

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL environment variable bulunamadı.")


def connect():
    return psycopg2.connect(
        DATABASE_URL,
        cursor_factory=RealDictCursor
    )


def create_tables():
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS players(
        id SERIAL PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        nickname TEXT,
        company TEXT DEFAULT '',
        level INTEGER DEFAULT 1,
        exp BIGINT DEFAULT 0,
        honor BIGINT DEFAULT 0,
        bitcoin BIGINT DEFAULT 0,
        plt BIGINT DEFAULT 0,
        ship TEXT DEFAULT 'Başlangıç Gemisi',
        map TEXT DEFAULT '',
        pos_x INTEGER DEFAULT 0,
        pos_y INTEGER DEFAULT 0
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS inventory(
        id SERIAL PRIMARY KEY,
        player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        item_type TEXT,
        item_name TEXT,
        amount INTEGER DEFAULT 1
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS ships(
        id SERIAL PRIMARY KEY,
        player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        ship_name TEXT,
        active INTEGER DEFAULT 0
    )
    """)

    db.commit()
    cursor.close()
    db.close()


def create_player(username, password, nickname, company=""):
    db = connect()
    cursor = db.cursor()
    try:
        cursor.execute("""
        INSERT INTO players(username, password, nickname, company, map)
        VALUES(%s,%s,%s,%s,%s)
        RETURNING id
        """, (username, password, nickname, company.strip().upper(), ""))

        row = cursor.fetchone()
        player_id = row["id"]

        cursor.execute("""
        INSERT INTO ships(player_id, ship_name, active)
        VALUES(%s,%s,%s)
        """, (player_id, "Ship10", 1))

        db.commit()
        return player_id
    except psycopg2.IntegrityError:
        db.rollback()
        return None
    finally:
        cursor.close()
        db.close()


def login_player(username, password):
    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    SELECT * FROM players
    WHERE username=%s AND password=%s
    """, (username, password))
    row = cursor.fetchone()
    cursor.close()
    db.close()
    return row


def get_player(player_id):
    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players WHERE id=%s", (player_id,))
    row = cursor.fetchone()
    cursor.close()
    db.close()
    return row


def get_player_by_username(username):
    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players WHERE username=%s", (username,))
    row = cursor.fetchone()
    cursor.close()
    db.close()
    return row


def set_player_company_by_username(username, company):
    company = company.strip().upper()

    if company == "EIC":
        start_map = "2-1"
    elif company == "VRU":
        start_map = "3-1"
    elif company == "MMO":
        start_map = "1-1"
    else:
        return False, "", ""

    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    UPDATE players
    SET company=%s, map=%s, pos_x=0, pos_y=0
    WHERE username=%s
    """, (company, start_map, username))
    changed = cursor.rowcount
    db.commit()
    cursor.close()
    db.close()
    return changed > 0, company, start_map


def change_nickname(player_id, new_nickname):
    db = connect()
    cursor = db.cursor()
    try:
        cursor.execute("""
        UPDATE players SET nickname=%s WHERE id=%s
        """, (new_nickname, player_id))
        changed = cursor.rowcount
        db.commit()
        return changed > 0
    except psycopg2.IntegrityError:
        db.rollback()
        return False
    finally:
        cursor.close()
        db.close()


def add_player_plt_by_username(username, amount):
    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    UPDATE players SET plt = plt + %s WHERE username=%s
    """, (amount, username))
    changed = cursor.rowcount
    db.commit()
    cursor.close()
    db.close()
    return changed > 0


def adjust_player_economy(username, bitcoin_delta=0, plt_delta=0, xp_delta=0, honor_delta=0):
    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    UPDATE players
    SET bitcoin = bitcoin + %s,
        plt = plt + %s,
        exp = exp + %s,
        honor = honor + %s
    WHERE username = %s
      AND bitcoin + %s >= 0
      AND plt + %s >= 0
    """, (
        bitcoin_delta, plt_delta, xp_delta, honor_delta,
        username, bitcoin_delta, plt_delta
    ))
    changed = cursor.rowcount
    db.commit()
    cursor.close()
    db.close()
    return changed > 0


def get_player_assets_by_username(username):
    db = connect()
    cursor = db.cursor()

    cursor.execute("SELECT id FROM players WHERE username=%s", (username,))
    player = cursor.fetchone()
    if not player:
        cursor.close()
        db.close()
        return {
            "owned_ships": [],
            "inventory": {},
            "droid_types": []
        }

    player_id = player["id"]

    cursor.execute("""
    SELECT ship_name FROM ships
    WHERE player_id=%s
    ORDER BY id
    """, (player_id,))
    owned_ships = []
    for row in cursor.fetchall():
        ship_name = str(row["ship_name"])
        if ship_name == "Başlangıç Gemisi":
            ship_name = "Ship10"
        if ship_name not in owned_ships:
            owned_ships.append(ship_name)

    if "Ship10" not in owned_ships:
        owned_ships.insert(0, "Ship10")

    cursor.execute("""
    SELECT item_type, item_name, amount
    FROM inventory
    WHERE player_id=%s
    ORDER BY id
    """, (player_id,))

    inventory = {}
    droid_types = []

    for row in cursor.fetchall():
        item_type = str(row["item_type"] or "")
        item_name = str(row["item_name"] or "")
        amount = int(row["amount"] or 0)

        if item_type == "droid":
            for _ in range(max(0, amount)):
                droid_types.append(item_name.upper())
        else:
            inventory[item_name] = inventory.get(item_name, 0) + amount

    cursor.close()
    db.close()

    return {
        "owned_ships": owned_ships,
        "inventory": inventory,
        "droid_types": droid_types
    }


def _add_inventory_item(cursor, player_id, item_type, item_name, amount=1):
    cursor.execute("""
    SELECT id, amount
    FROM inventory
    WHERE player_id=%s AND item_type=%s AND item_name=%s
    ORDER BY id
    LIMIT 1
    FOR UPDATE
    """, (player_id, item_type, item_name))
    row = cursor.fetchone()

    if row:
        cursor.execute("""
        UPDATE inventory
        SET amount=%s
        WHERE id=%s
        """, (int(row["amount"]) + amount, row["id"]))
    else:
        cursor.execute("""
        INSERT INTO inventory(player_id, item_type, item_name, amount)
        VALUES(%s,%s,%s,%s)
        """, (player_id, item_type, item_name, amount))


def buy_market_item_by_username(username, kind, item_id, currency, price):
    currency = currency.upper()
    kind = kind.lower()

    db = connect()
    cursor = db.cursor()

    try:
        cursor.execute("""
        SELECT id, bitcoin, plt
        FROM players
        WHERE username=%s
        FOR UPDATE
        """, (username,))
        player = cursor.fetchone()

        if not player:
            db.rollback()
            return False, "Oyuncu bulunamadı", None

        player_id = player["id"]
        bitcoin = int(player["bitcoin"])
        plt = int(player["plt"])

        if kind == "ship":
            cursor.execute("""
            SELECT id FROM ships
            WHERE player_id=%s AND ship_name=%s
            LIMIT 1
            """, (player_id, item_id))
            if cursor.fetchone():
                db.rollback()
                return False, "Bu gemiye zaten sahipsin.", None

        if currency == "BTC":
            if bitcoin < price:
                db.rollback()
                return False, "Yeterli Bitcoin yok.", None
            bitcoin -= price
        elif currency == "PLT":
            if plt < price:
                db.rollback()
                return False, "Yeterli PLT yok.", None
            plt -= price
        elif currency != "FREE":
            db.rollback()
            return False, "Geçersiz para birimi.", None

        cursor.execute("""
        UPDATE players
        SET bitcoin=%s, plt=%s
        WHERE id=%s
        """, (bitcoin, plt, player_id))

        if kind == "ship":
            cursor.execute("""
            INSERT INTO ships(player_id, ship_name, active)
            VALUES(%s,%s,0)
            """, (player_id, item_id))
        elif kind == "equipment":
            _add_inventory_item(cursor, player_id, "equipment", item_id, 1)
        else:
            db.rollback()
            return False, "Geçersiz market ürün tipi.", None

        db.commit()
        return True, "Satın alma başarılı.", {
            "bitcoin": bitcoin,
            "plt": plt
        }

    except Exception:
        db.rollback()
        raise
    finally:
        cursor.close()
        db.close()


def buy_droid_by_username(username, droid_type, currency, price_steps):
    droid_type = droid_type.upper()
    currency = currency.upper()

    db = connect()
    cursor = db.cursor()

    try:
        cursor.execute("""
        SELECT id, bitcoin, plt
        FROM players
        WHERE username=%s
        FOR UPDATE
        """, (username,))
        player = cursor.fetchone()

        if not player:
            db.rollback()
            return False, "Oyuncu bulunamadı", None

        player_id = player["id"]

        cursor.execute("""
        SELECT item_name, amount
        FROM inventory
        WHERE player_id=%s AND item_type='droid'
        FOR UPDATE
        """, (player_id,))
        rows = cursor.fetchall()

        total_droids = sum(int(r["amount"] or 0) for r in rows)
        same_type_count = sum(
            int(r["amount"] or 0)
            for r in rows
            if str(r["item_name"]).upper() == droid_type
        )

        if total_droids >= 8:
            db.rollback()
            return False, "Maksimum 8 droid sınırına ulaşıldı.", None

        price_index = min(same_type_count, len(price_steps) - 1)
        price = int(price_steps[price_index])

        bitcoin = int(player["bitcoin"])
        plt = int(player["plt"])

        if currency == "BTC":
            if bitcoin < price:
                db.rollback()
                return False, "Yeterli Bitcoin yok.", None
            bitcoin -= price
        elif currency == "PLT":
            if plt < price:
                db.rollback()
                return False, "Yeterli PLT yok.", None
            plt -= price
        else:
            db.rollback()
            return False, "Geçersiz para birimi.", None

        cursor.execute("""
        UPDATE players
        SET bitcoin=%s, plt=%s
        WHERE id=%s
        """, (bitcoin, plt, player_id))

        _add_inventory_item(cursor, player_id, "droid", droid_type, 1)

        db.commit()
        return True, "%s droid satın alındı." % droid_type, {
            "bitcoin": bitcoin,
            "plt": plt,
            "price": price,
            "total_droids": total_droids + 1,
            "same_type_count": same_type_count + 1
        }

    except Exception:
        db.rollback()
        raise
    finally:
        cursor.close()
        db.close()

# === NovaGate MMO Core V2 ===
import math
import random
import time


NPC_SERVER_STATS = {
    "zyron_raider": {"attack_range": 430.0, "damage": 900.0, "interval": 1.0},
    "nexar_fighter": {"attack_range": 440.0, "damage": 1500.0, "interval": 1.0},
    "nexar_destroyer": {"attack_range": 450.0, "damage": 2200.0, "interval": 1.0},
    "nexar_warlord": {"attack_range": 460.0, "damage": 3200.0, "interval": 1.0},
    "void_reaper": {"attack_range": 475.0, "damage": 4700.0, "interval": 1.0},
    "void_predator": {"attack_range": 490.0, "damage": 6500.0, "interval": 1.0},
    "abyss_guardian": {"attack_range": 500.0, "damage": 8500.0, "interval": 1.0},
    "void_ravager": {"attack_range": 510.0, "damage": 11000.0, "interval": 1.0},
    "titan_nemesis": {"attack_range": 550.0, "damage": 18000.0, "interval": 1.0},
}

COMBAT_LOGOUT_SECONDS = 5.0
HEARTBEAT_TIMEOUT_SECONDS = 2.5


def ensure_online_world_tables():
    db = connect()
    c = db.cursor()

    c.execute("""CREATE TABLE IF NOT EXISTS player_effects(
        player_id INTEGER PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
        ema_end DOUBLE PRECISION DEFAULT 0,
        nukleer_end DOUBLE PRECISION DEFAULT 0,
        onluk_end DOUBLE PRECISION DEFAULT 0,
        enc_cooldown_end DOUBLE PRECISION DEFAULT 0,
        enc_active_end DOUBLE PRECISION DEFAULT 0,
        kalkan_cooldown_end DOUBLE PRECISION DEFAULT 0,
        kalkan_active_end DOUBLE PRECISION DEFAULT 0,
        updated_at DOUBLE PRECISION DEFAULT 0
    )""")

    c.execute("""CREATE TABLE IF NOT EXISTS npc_world(
        npc_id TEXT PRIMARY KEY,
        map TEXT NOT NULL,
        npc_type TEXT NOT NULL,
        pos_x DOUBLE PRECISION NOT NULL,
        pos_y DOUBLE PRECISION NOT NULL,
        health DOUBLE PRECISION NOT NULL,
        shield DOUBLE PRECISION NOT NULL DEFAULT 0,
        max_health DOUBLE PRECISION NOT NULL,
        max_shield DOUBLE PRECISION NOT NULL DEFAULT 0,
        move_speed DOUBLE PRECISION NOT NULL,
        passive BOOLEAN DEFAULT FALSE,
        alive BOOLEAN DEFAULT TRUE,
        respawn_at DOUBLE PRECISION DEFAULT 0,
        updated_at DOUBLE PRECISION DEFAULT 0,
        target_username TEXT DEFAULT '',
        first_attacker_username TEXT DEFAULT '',
        home_x DOUBLE PRECISION DEFAULT 0,
        home_y DOUBLE PRECISION DEFAULT 0,
        last_attack_at DOUBLE PRECISION DEFAULT 0
    )""")

    # Existing V1 databases are migrated safely.
    for sql in [
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS last_seen DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS health DOUBLE PRECISION DEFAULT 400000",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS shield DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS max_health DOUBLE PRECISION DEFAULT 400000",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS max_shield DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS last_damage_at DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS combat_until DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS logout_requested_at DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS logout_deadline DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS session_active BOOLEAN DEFAULT FALSE",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS alive BOOLEAN DEFAULT TRUE",
        "ALTER TABLE players ADD COLUMN IF NOT EXISTS respawn_at DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS max_shield DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS target_username TEXT DEFAULT ''",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS first_attacker_username TEXT DEFAULT ''",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS home_x DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS home_y DOUBLE PRECISION DEFAULT 0",
        "ALTER TABLE npc_world ADD COLUMN IF NOT EXISTS last_attack_at DOUBLE PRECISION DEFAULT 0",
    ]:
        c.execute(sql)

    db.commit()
    c.close()
    db.close()


def update_player_presence(username, map_name, x, y, now_ts, health=None, shield=None, max_health=None, max_shield=None):
    db = connect()
    c = db.cursor()

    fields = [
        "map=%s", "pos_x=%s", "pos_y=%s", "last_seen=%s",
        "session_active=TRUE", "logout_requested_at=0", "logout_deadline=0"
    ]
    values = [map_name, int(x), int(y), float(now_ts)]

    if health is not None and health >= 0:
        fields.append("health=%s")
        values.append(float(health))
        fields.append("alive=%s")
        values.append(float(health) > 0.0)
    if shield is not None and shield >= 0:
        fields.append("shield=%s")
        values.append(float(shield))
    if max_health is not None and max_health > 0:
        fields.append("max_health=%s")
        values.append(float(max_health))
    if max_shield is not None and max_shield >= 0:
        fields.append("max_shield=%s")
        values.append(float(max_shield))

    values.append(username)
    c.execute(
        "UPDATE players SET " + ",".join(fields) + " WHERE username=%s",
        tuple(values)
    )
    changed = c.rowcount

    c.execute("SELECT health,shield,alive FROM players WHERE username=%s", (username,))
    row = c.fetchone()

    db.commit()
    c.close()
    db.close()
    return changed > 0, row


def get_online_players(map_name, now_ts, exclude_username=""):
    db = connect()
    c = db.cursor()
    c.execute("""
        SELECT id,username,nickname,company,ship,map,pos_x,pos_y,last_seen,
               health,shield,max_health,max_shield,alive,session_active
        FROM players
        WHERE map=%s
          AND session_active=TRUE
          AND alive=TRUE
          AND username<>%s
        ORDER BY id
    """, (map_name, exclude_username))
    rows = c.fetchall()
    c.close()
    db.close()
    return rows


def get_player_world_state(username):
    db = connect()
    c = db.cursor()
    c.execute("""
        SELECT username,map,pos_x,pos_y,health,shield,max_health,max_shield,
               alive,last_seen,last_damage_at,combat_until,
               logout_requested_at,logout_deadline,session_active
        FROM players
        WHERE username=%s
    """, (username,))
    row = c.fetchone()
    c.close()
    db.close()
    return row


def update_player_damage_state(username, health, shield, map_name, x, y, now_ts):
    db = connect()
    c = db.cursor()
    alive = float(health) > 0.0
    deadline = float(now_ts) + COMBAT_LOGOUT_SECONDS

    c.execute("""
        UPDATE players
        SET health=%s,
            shield=%s,
            map=%s,
            pos_x=%s,
            pos_y=%s,
            alive=%s,
            last_damage_at=%s,
            combat_until=%s,
            logout_deadline=CASE
                WHEN logout_requested_at > 0 THEN %s
                ELSE logout_deadline
            END
        WHERE username=%s
    """, (
        float(health), float(shield), map_name, int(x), int(y), alive,
        float(now_ts), deadline, deadline, username
    ))

    c.execute("SELECT health,shield,alive FROM players WHERE username=%s", (username,))
    row = c.fetchone()
    db.commit()
    c.close()
    db.close()
    return row


def request_player_logout(username, map_name, x, y, health, shield, now_ts):
    db = connect()
    c = db.cursor()
    deadline = float(now_ts) + COMBAT_LOGOUT_SECONDS

    c.execute("""
        UPDATE players
        SET map=%s,pos_x=%s,pos_y=%s,health=%s,shield=%s,
            logout_requested_at=%s,logout_deadline=%s
        WHERE username=%s
    """, (
        map_name, int(x), int(y), float(health), float(shield),
        float(now_ts), deadline, username
    ))

    c.execute("""
        SELECT logout_deadline,combat_until,last_damage_at,alive
        FROM players WHERE username=%s
    """, (username,))
    row = c.fetchone()
    db.commit()
    c.close()
    db.close()
    return row


def repair_player_world_state(username, map_name, x, y, health, shield, max_health, max_shield, now_ts):
    db = connect()
    c = db.cursor()
    c.execute("""
        UPDATE players
        SET map=%s,pos_x=%s,pos_y=%s,
            health=%s,shield=%s,max_health=%s,max_shield=%s,
            alive=TRUE,respawn_at=0,
            last_seen=%s,session_active=TRUE,
            logout_requested_at=0,logout_deadline=0,combat_until=0
        WHERE username=%s
    """, (
        map_name, int(x), int(y), float(health), float(shield),
        float(max_health), float(max_shield), float(now_ts), username
    ))
    changed = c.rowcount
    db.commit()
    c.close()
    db.close()
    return changed > 0


def get_effects(username):
    db=connect(); c=db.cursor()
    c.execute("SELECT id FROM players WHERE username=%s",(username,))
    p=c.fetchone()
    if not p:
        c.close(); db.close(); return None
    c.execute("INSERT INTO player_effects(player_id) VALUES(%s) ON CONFLICT(player_id) DO NOTHING",(p['id'],))
    db.commit()
    c.execute("SELECT * FROM player_effects WHERE player_id=%s",(p['id'],))
    row=c.fetchone()
    c.close(); db.close()
    return row


def set_effect(username, key, cooldown_end, active_end, now_ts):
    allowed={
        'ema':('ema_end',None),
        'nukleer':('nukleer_end',None),
        'onluk':('onluk_end',None),
        'enc':('enc_cooldown_end','enc_active_end'),
        'kalkan':('kalkan_cooldown_end','kalkan_active_end')
    }
    if key not in allowed:
        return False
    db=connect(); c=db.cursor()
    c.execute("SELECT id FROM players WHERE username=%s",(username,))
    p=c.fetchone()
    if not p:
        c.close(); db.close(); return False
    c.execute("INSERT INTO player_effects(player_id) VALUES(%s) ON CONFLICT(player_id) DO NOTHING",(p['id'],))
    cd,active=allowed[key]
    if active:
        c.execute(
            f"UPDATE player_effects SET {cd}=%s,{active}=%s,updated_at=%s WHERE player_id=%s",
            (float(cooldown_end),float(active_end),float(now_ts),p['id'])
        )
    else:
        c.execute(
            f"UPDATE player_effects SET {cd}=%s,updated_at=%s WHERE player_id=%s",
            (float(cooldown_end),float(now_ts),p['id'])
        )
    db.commit(); c.close(); db.close()
    return True


def get_npc_world(map_name):
    db=connect(); c=db.cursor()
    c.execute("SELECT * FROM npc_world WHERE map=%s ORDER BY npc_id",(map_name,))
    rows=c.fetchall()
    c.close(); db.close()
    return rows


def upsert_npc_world(
    npc_id,map_name,npc_type,x,y,health,shield,max_health,move_speed,
    passive,alive,respawn_at,now_ts,max_shield=0,
    target_username="",first_attacker_username="",home_x=None,home_y=None
):
    db=connect(); c=db.cursor()

    hx = float(x if home_x is None else home_x)
    hy = float(y if home_y is None else home_y)

    c.execute("""
        INSERT INTO npc_world(
            npc_id,map,npc_type,pos_x,pos_y,health,shield,max_health,max_shield,
            move_speed,passive,alive,respawn_at,updated_at,
            target_username,first_attacker_username,home_x,home_y,last_attack_at
        )
        VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,0)
        ON CONFLICT(npc_id) DO UPDATE SET
            map=EXCLUDED.map,
            npc_type=EXCLUDED.npc_type,
            pos_x=EXCLUDED.pos_x,
            pos_y=EXCLUDED.pos_y,
            health=EXCLUDED.health,
            shield=EXCLUDED.shield,
            max_health=EXCLUDED.max_health,
            max_shield=EXCLUDED.max_shield,
            move_speed=EXCLUDED.move_speed,
            passive=EXCLUDED.passive,
            alive=EXCLUDED.alive,
            respawn_at=EXCLUDED.respawn_at,
            updated_at=EXCLUDED.updated_at,
            target_username=CASE
                WHEN npc_world.target_username<>'' THEN npc_world.target_username
                ELSE EXCLUDED.target_username
            END,
            first_attacker_username=CASE
                WHEN npc_world.first_attacker_username<>'' THEN npc_world.first_attacker_username
                ELSE EXCLUDED.first_attacker_username
            END,
            home_x=CASE WHEN npc_world.home_x=0 THEN EXCLUDED.home_x ELSE npc_world.home_x END,
            home_y=CASE WHEN npc_world.home_y=0 THEN EXCLUDED.home_y ELSE npc_world.home_y END
    """, (
        npc_id,map_name,npc_type,float(x),float(y),float(health),float(shield),
        float(max_health),float(max_shield),float(move_speed),bool(passive),
        bool(alive),float(respawn_at),float(now_ts),
        target_username or "",first_attacker_username or "",hx,hy
    ))
    db.commit(); c.close(); db.close()
    return True


def upsert_world_npcs_batch(npcs):
    if not npcs:
        return True

    db = connect()
    c = db.cursor()
    try:
        for npc in npcs:
            npc_id = str(npc.get("npc_id", ""))
            if not npc_id:
                continue

            map_name = str(npc.get("map_name", npc.get("map", "")))
            x = float(npc.get("pos_x", npc.get("x", 0)))
            y = float(npc.get("pos_y", npc.get("y", 0)))
            first_owner = str(npc.get("first_attacker_username", ""))
            target = str(npc.get("target_username", first_owner))
            home_x = float(npc.get("home_x", x))
            home_y = float(npc.get("home_y", y))

            c.execute("""
                INSERT INTO npc_world(
                    npc_id,map,npc_type,pos_x,pos_y,health,shield,
                    max_health,max_shield,move_speed,passive,alive,
                    respawn_at,updated_at,target_username,first_attacker_username,
                    home_x,home_y,last_attack_at
                )
                VALUES(
                    %s,%s,%s,%s,%s,%s,%s,
                    %s,%s,%s,%s,%s,
                    0,%s,%s,%s,%s,%s,0
                )
                ON CONFLICT(npc_id) DO UPDATE SET
                    map=EXCLUDED.map,
                    npc_type=EXCLUDED.npc_type,
                    pos_x=EXCLUDED.pos_x,
                    pos_y=EXCLUDED.pos_y,
                    health=EXCLUDED.health,
                    shield=EXCLUDED.shield,
                    max_health=EXCLUDED.max_health,
                    max_shield=EXCLUDED.max_shield,
                    move_speed=EXCLUDED.move_speed,
                    passive=EXCLUDED.passive,
                    alive=EXCLUDED.alive,
                    updated_at=EXCLUDED.updated_at,
                    first_attacker_username=CASE
                        WHEN npc_world.first_attacker_username<>'' THEN npc_world.first_attacker_username
                        ELSE EXCLUDED.first_attacker_username
                    END,
                    target_username=CASE
                        WHEN npc_world.target_username<>'' THEN npc_world.target_username
                        ELSE EXCLUDED.target_username
                    END,
                    home_x=CASE WHEN npc_world.home_x=0 THEN EXCLUDED.home_x ELSE npc_world.home_x END,
                    home_y=CASE WHEN npc_world.home_y=0 THEN EXCLUDED.home_y ELSE npc_world.home_y END
            """, (
                npc_id,map_name,str(npc.get("npc_type","")),
                x,y,float(npc.get("health",0)),float(npc.get("shield",0)),
                float(npc.get("max_health",0)),float(npc.get("max_shield",0)),
                float(npc.get("move_speed",0)),bool(npc.get("passive",False)),
                bool(npc.get("alive",True)),float(time.time()),
                target,first_owner,home_x,home_y
            ))

        db.commit()
        return True
    except Exception:
        db.rollback()
        raise
    finally:
        c.close()
        db.close()


def claim_npc_first_attacker(npc_id, username):
    db = connect()
    c = db.cursor()

    c.execute("""
        UPDATE npc_world
        SET first_attacker_username=CASE
                WHEN first_attacker_username='' THEN %s
                ELSE first_attacker_username
            END,
            target_username=CASE
                WHEN target_username='' THEN %s
                ELSE target_username
            END
        WHERE npc_id=%s
        RETURNING first_attacker_username,target_username
    """, (username, username, npc_id))
    row = c.fetchone()
    db.commit()
    c.close()
    db.close()
    return row


def mark_npc_dead(payload, now_ts):
    db = connect()
    c = db.cursor()
    npc_id = str(payload.get("npc_id",""))
    c.execute("""
        UPDATE npc_world
        SET alive=FALSE,
            health=0,
            shield=0,
            respawn_at=%s,
            target_username='',
            updated_at=%s
        WHERE npc_id=%s
    """, (
        float(payload.get("respawn_at", now_ts + 6.0)),
        float(now_ts),
        npc_id
    ))
    changed = c.rowcount
    db.commit()
    c.close()
    db.close()
    return changed > 0


def _finish_safe_logout(c, username):
    c.execute("""
        UPDATE players
        SET session_active=FALSE,
            logout_requested_at=0,
            logout_deadline=0
        WHERE username=%s
    """, (username,))
    c.execute("""
        UPDATE npc_world
        SET target_username=''
        WHERE target_username=%s
    """, (username,))


def world_tick_once(now_ts):
    db = connect()
    c = db.cursor()
    try:
        # Connection loss fallback: if heartbeat vanished, start safe logout.
        c.execute("""
            UPDATE players
            SET logout_requested_at=CASE WHEN logout_requested_at=0 THEN %s ELSE logout_requested_at END,
                logout_deadline=CASE WHEN logout_deadline=0 THEN %s ELSE logout_deadline END
            WHERE session_active=TRUE
              AND last_seen < %s
              AND logout_requested_at=0
        """, (
            float(now_ts),
            float(now_ts + COMBAT_LOGOUT_SECONDS),
            float(now_ts - HEARTBEAT_TIMEOUT_SECONDS)
        ))

        # NPC server combat only takes over when the target client is no longer
        # heartbeating / is in logout grace. While online, existing Godot combat
        # stays authoritative to avoid double hits.
        c.execute("""
            SELECT n.*,
                   p.username AS p_username,p.map AS p_map,
                   p.pos_x AS p_x,p.pos_y AS p_y,
                   p.health AS p_health,p.shield AS p_shield,
                   p.alive AS p_alive,p.session_active AS p_session_active,
                   p.last_seen AS p_last_seen,p.logout_requested_at,
                   p.logout_deadline
            FROM npc_world n
            JOIN players p ON p.username=n.target_username
            WHERE n.alive=TRUE
              AND n.target_username<>''
              AND p.alive=TRUE
        """)
        fights = c.fetchall()

        for row in fights:
            disconnected = float(row["p_last_seen"] or 0) < now_ts - HEARTBEAT_TIMEOUT_SECONDS
            in_logout = float(row["logout_requested_at"] or 0) > 0

            if not disconnected and not in_logout:
                continue
            if str(row["map"]) != str(row["p_map"]):
                continue

            stats = NPC_SERVER_STATS.get(str(row["npc_type"]), {
                "attack_range": 450.0,
                "damage": 1000.0,
                "interval": 1.0
            })

            nx, ny = float(row["pos_x"]), float(row["pos_y"])
            px, py = float(row["p_x"]), float(row["p_y"])
            dx, dy = px - nx, py - ny
            dist = math.hypot(dx, dy)

            attack_range = float(stats["attack_range"])
            move_speed = max(0.0, float(row["move_speed"] or 0.0))

            if dist > attack_range and dist > 0.001:
                step = min(move_speed * 0.5, max(0.0, dist - attack_range * 0.92))
                nx += dx / dist * step
                ny += dy / dist * step
                c.execute(
                    "UPDATE npc_world SET pos_x=%s,pos_y=%s,updated_at=%s WHERE npc_id=%s",
                    (nx, ny, float(now_ts), row["npc_id"])
                )
                dist = math.hypot(px - nx, py - ny)

            last_attack = float(row["last_attack_at"] or 0.0)
            interval = float(stats["interval"])
            if dist <= attack_range and now_ts - last_attack >= interval:
                damage = float(stats["damage"])
                shield = max(0.0, float(row["p_shield"] or 0.0))
                hp = max(0.0, float(row["p_health"] or 0.0))

                absorbed = min(shield, damage)
                shield -= absorbed
                hp = max(0.0, hp - (damage - absorbed))
                alive = hp > 0.0
                new_deadline = float(now_ts + COMBAT_LOGOUT_SECONDS)

                c.execute("""
                    UPDATE players
                    SET health=%s,shield=%s,alive=%s,
                        last_damage_at=%s,combat_until=%s,
                        logout_deadline=%s
                    WHERE username=%s
                """, (
                    hp,shield,alive,float(now_ts),new_deadline,new_deadline,row["p_username"]
                ))
                c.execute(
                    "UPDATE npc_world SET last_attack_at=%s,updated_at=%s WHERE npc_id=%s",
                    (float(now_ts),float(now_ts),row["npc_id"])
                )

                if not alive:
                    _finish_safe_logout(c, row["p_username"])

        # Safe logout succeeds only after 5 full damage-free seconds.
        c.execute("""
            SELECT username
            FROM players
            WHERE session_active=TRUE
              AND logout_requested_at>0
              AND logout_deadline>0
              AND logout_deadline<=%s
              AND alive=TRUE
        """, (float(now_ts),))
        for row in c.fetchall():
            _finish_safe_logout(c, row["username"])

        # Server NPC respawn continues even with no client in the map.
        c.execute("""
            SELECT *
            FROM npc_world
            WHERE alive=FALSE
              AND respawn_at>0
              AND respawn_at<=%s
        """, (float(now_ts),))
        for row in c.fetchall():
            hx = float(row["home_x"] or row["pos_x"])
            hy = float(row["home_y"] or row["pos_y"])
            angle = random.random() * math.tau
            radius = random.uniform(250.0, 1200.0)
            x = hx + math.cos(angle) * radius
            y = hy + math.sin(angle) * radius
            c.execute("""
                UPDATE npc_world
                SET pos_x=%s,pos_y=%s,
                    health=max_health,shield=max_shield,
                    alive=TRUE,respawn_at=0,
                    target_username='',first_attacker_username='',
                    last_attack_at=0,updated_at=%s
                WHERE npc_id=%s
            """, (x,y,float(now_ts),row["npc_id"]))

        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        c.close()
        db.close()
