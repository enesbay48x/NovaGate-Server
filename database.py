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

    # NovaGate Ranking V1 - mevcut hesapları silmeden yeni istatistik alanları.
    rank_columns = [
        ("npc_kills", "BIGINT DEFAULT 0"),
        ("player_kills", "BIGINT DEFAULT 0"),
        ("friendly_kills", "BIGINT DEFAULT 0"),
        ("deaths", "BIGINT DEFAULT 0"),
        ("radiation_deaths", "BIGINT DEFAULT 0"),
        ("starter_ship_kills", "BIGINT DEFAULT 0"),
        ("missions_completed", "BIGINT DEFAULT 0"),
        ("registered_at", "TIMESTAMPTZ DEFAULT NOW()"),
        ("is_admin", "BOOLEAN DEFAULT FALSE")
    ]
    for column_name, column_type in rank_columns:
        cursor.execute(
            "ALTER TABLE players ADD COLUMN IF NOT EXISTS %s %s" % (column_name, column_type)
        )

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

    # NovaGate Clan System V1
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clans(
        id SERIAL PRIMARY KEY,
        name TEXT UNIQUE NOT NULL,
        tag TEXT UNIQUE NOT NULL,
        leader_username TEXT NOT NULL,
        company TEXT DEFAULT '',
        description TEXT DEFAULT '',
        treasury_bitcoin BIGINT DEFAULT 0,
        tax_rate DOUBLE PRECISION DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clan_roles(
        id SERIAL PRIMARY KEY,
        clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        priority INTEGER DEFAULT 10,
        permissions JSONB DEFAULT '{}'::jsonb,
        UNIQUE(clan_id, name)
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clan_members(
        clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        username TEXT NOT NULL UNIQUE,
        role_name TEXT DEFAULT 'Üye',
        joined_at TIMESTAMPTZ DEFAULT NOW(),
        PRIMARY KEY(clan_id, username)
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clan_applications(
        id SERIAL PRIMARY KEY,
        clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        username TEXT NOT NULL,
        message TEXT DEFAULT '',
        status TEXT DEFAULT 'pending',
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(clan_id, username)
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clan_diplomacy(
        id SERIAL PRIMARY KEY,
        clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        target_clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        relation TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        requested_by TEXT DEFAULT '',
        created_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(clan_id, target_clan_id, relation)
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS clan_messages(
        id SERIAL PRIMARY KEY,
        clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
        username TEXT NOT NULL,
        message TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )
    """)

    cursor.execute("ALTER TABLE players ADD COLUMN IF NOT EXISTS last_clan_tax_at TIMESTAMPTZ DEFAULT NOW()")

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

        apply_daily_clan_tax(now_ts)

        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        c.close()
        db.close()


# ============================================================
# NOVAGATE RANKING V1
from datetime import datetime, timezone
# DarkOrbit-style dynamic company ranking.
# ============================================================

RANK_ORDER = [
    ("private", "Er"),
    ("sergeant", "Çavuş"),
    ("lieutenant", "Teğmen"),
    ("captain", "Yüzbaşı"),
    ("major", "Binbaşı"),
    ("colonel", "Albay"),
    ("gen-col", "Kurmay Albay"),
    ("gen-maj", "Tümgeneral"),
    ("general", "General"),
    ("marshal", "Mareşal"),
]

# Üstten aşağı kümülatif dilimler. Küçük oyuncu sayılarında da rütbe sistemi
# çalışsın diye kontenjan hesabında minimum 1 kişi korunur.
RANK_TOP_PERCENT = {
    "marshal": 0.01,
    "general": 0.05,
    "gen-maj": 0.20,
    "gen-col": 0.75,
    "colonel": 2.00,
    "major": 5.00,
    "captain": 12.00,
    "lieutenant": 25.00,
    "sergeant": 45.00,
    "private": 100.00,
}

SHIP_RANK_VALUE = {
    "Ship10": 1, "Başlangıç Gemisi": 1,
    "Ship20": 2, "Ship40": 3, "Ship50": 4, "Ship60": 5,
    "Ship70": 6, "Ship80": 7, "Ship100": 8, "Ship106": 10,
}


def _rank_points_from_row(row):
    if not row:
        return 0.0
    exp = float(row.get("exp", 0) or 0)
    honor = float(row.get("honor", 0) or 0)
    level = int(row.get("level", 1) or 1)
    npc_kills = int(row.get("npc_kills", 0) or 0)
    player_kills = int(row.get("player_kills", 0) or 0)
    friendly_kills = int(row.get("friendly_kills", 0) or 0)
    deaths = int(row.get("deaths", 0) or 0)
    radiation_deaths = int(row.get("radiation_deaths", 0) or 0)
    starter_ship_kills = int(row.get("starter_ship_kills", 0) or 0)
    missions_completed = int(row.get("missions_completed", 0) or 0)
    ship_value = SHIP_RANK_VALUE.get(str(row.get("ship", "Ship10")), 1)

    registered_at = row.get("registered_at")
    days_registered = 0
    if registered_at is not None:
        try:
            from datetime import datetime, timezone
            now = datetime.now(timezone.utc)
            dt = registered_at
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            days_registered = max(0, (now - dt).days)
        except Exception:
            days_registered = 0

    # DarkOrbit formülünün NovaGate'teki mevcut sayaçlara uyarlanmış hali.
    points = (
        exp / 100000.0
        + honor / 100.0
        + player_kills * 3.0
        + level * 100.0
        + days_registered * 6.0
        + ship_value * 1000.0
        + npc_kills / 2.0
        + missions_completed * 100.0
        - friendly_kills * 100.0
        - deaths * 4.0
        - radiation_deaths * 8.0
        - starter_ship_kills * 2.0
    )
    return max(0.0, points)


def _normal_rank_for_position(position, company_count):
    if company_count <= 0:
        return ("private", "Er")
    percentile = (float(position) / float(company_count)) * 100.0
    for key in ["marshal","general","gen-maj","gen-col","colonel","major","captain","lieutenant","sergeant","private"]:
        threshold = RANK_TOP_PERCENT[key]
        quota = max(1, int((company_count * threshold) / 100.0 + 0.999999))
        if position <= quota:
            for rk, title in RANK_ORDER:
                if rk == key:
                    return (rk, title)
    return ("private", "Er")


def get_player_ranking(username):
    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players WHERE username=%s", (username,))
    player = cursor.fetchone()
    if not player:
        cursor.close()
        db.close()
        return None

    company = str(player.get("company", "") or "")
    cursor.execute("SELECT * FROM players ORDER BY id")
    all_players = cursor.fetchall()
    cursor.close()
    db.close()

    scored = []
    for p in all_players:
        scored.append((p, _rank_points_from_row(p)))
    scored.sort(key=lambda item: (-item[1], int(item[0]["id"])))

    global_position = 1
    for i, (p, _) in enumerate(scored, start=1):
        if p["username"] == username:
            global_position = i
            break

    company_scored = [(p, pts) for p, pts in scored if str(p.get("company", "") or "") == company]
    company_position = 1
    for i, (p, _) in enumerate(company_scored, start=1):
        if p["username"] == username:
            company_position = i
            break

    points = _rank_points_from_row(player)

    # A rozeti sadece is_admin=true hesapta.
    if bool(player.get("is_admin", False)):
        rank_key, rank_title = "admin", "Admin"
    # Negatif şeref normal rütbe yerine traitor gösterir.
    elif int(player.get("honor", 0) or 0) < 0:
        rank_key, rank_title = "traitor", "Vatan Haini"
    else:
        rank_key, rank_title = _normal_rank_for_position(company_position, len(company_scored))

    next_rank_key = ""
    next_rank_title = ""
    next_rank_points = None
    normal_keys = [x[0] for x in RANK_ORDER]
    if rank_key in normal_keys:
        idx = normal_keys.index(rank_key)
        if idx < len(normal_keys) - 1:
            next_rank_key, next_rank_title = RANK_ORDER[idx + 1]
            # Bir üst rütbedeki en düşük oyuncunun mevcut puanını hedef olarak göster.
            candidates = []
            for pos, (p, pts) in enumerate(company_scored, start=1):
                rk, _ = _normal_rank_for_position(pos, len(company_scored))
                if rk == next_rank_key:
                    candidates.append(pts)
            if candidates:
                next_rank_points = min(candidates)

    return {
        "username": player["username"],
        "nickname": player.get("nickname", ""),
        "company": company,
        "rank_key": rank_key,
        "rank_title": rank_title,
        "rank_points": round(points, 2),
        "global_position": global_position,
        "global_count": len(scored),
        "company_position": company_position,
        "company_count": len(company_scored),
        "next_rank_key": next_rank_key,
        "next_rank_title": next_rank_title,
        "next_rank_points": next_rank_points,
        "npc_kills": int(player.get("npc_kills", 0) or 0),
        "player_kills": int(player.get("player_kills", 0) or 0),
        "friendly_kills": int(player.get("friendly_kills", 0) or 0),
        "deaths": int(player.get("deaths", 0) or 0),
        "missions_completed": int(player.get("missions_completed", 0) or 0),
        "days_registered": max(0, (datetime.now(timezone.utc) - (player.get("registered_at") if player.get("registered_at") is not None and player.get("registered_at").tzinfo is not None else (player.get("registered_at").replace(tzinfo=timezone.utc) if player.get("registered_at") is not None else datetime.now(timezone.utc)))).days),
        "exp": int(player.get("exp", 0) or 0),
        "honor": int(player.get("honor", 0) or 0),
        "is_admin": bool(player.get("is_admin", False)),
    }


def increment_rank_stat(username, stat_name, amount=1):
    allowed = {
        "npc_kills", "player_kills", "friendly_kills", "deaths",
        "radiation_deaths", "starter_ship_kills", "missions_completed"
    }
    if stat_name not in allowed:
        return False
    amount = max(0, int(amount))
    db = connect()
    cursor = db.cursor()
    cursor.execute(
        "UPDATE players SET " + stat_name + " = " + stat_name + " + %s WHERE username=%s",
        (amount, username)
    )
    changed = cursor.rowcount
    db.commit()
    cursor.close()
    db.close()
    return changed > 0


def set_admin_rank(username, enabled):
    db = connect()
    cursor = db.cursor()
    cursor.execute("UPDATE players SET is_admin=%s WHERE username=%s", (bool(enabled), username))
    changed = cursor.rowcount
    db.commit()
    cursor.close()
    db.close()
    return changed > 0


def get_ranking_leaderboard(limit=100, company=""):
    db = connect()
    cursor = db.cursor()
    if company:
        cursor.execute("SELECT * FROM players WHERE company=%s ORDER BY id", (company.strip().upper(),))
    else:
        cursor.execute("SELECT * FROM players ORDER BY id")
    rows = cursor.fetchall()
    cursor.close()
    db.close()

    scored = [(p, _rank_points_from_row(p)) for p in rows]
    scored.sort(key=lambda item: (-item[1], int(item[0]["id"])))
    result = []
    count = len(scored)
    for pos, (p, pts) in enumerate(scored[:max(1, min(int(limit), 500))], start=1):
        if bool(p.get("is_admin", False)):
            rk, title = "admin", "Admin"
        elif int(p.get("honor", 0) or 0) < 0:
            rk, title = "traitor", "Vatan Haini"
        else:
            rk, title = _normal_rank_for_position(pos, count)
        result.append({
            "position": pos,
            "username": p["username"],
            "nickname": p.get("nickname", ""),
            "company": p.get("company", ""),
            "rank_key": rk,
            "rank_title": title,
            "rank_points": round(pts, 2)
        })
    return result


def get_rank_snapshot_for_usernames(usernames):
    wanted = {str(x) for x in usernames if str(x)}
    if not wanted:
        return {}

    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players ORDER BY id")
    all_players = cursor.fetchall()
    cursor.close()
    db.close()

    scored = [(p, _rank_points_from_row(p)) for p in all_players]
    scored.sort(key=lambda item: (-item[1], int(item[0]["id"])))

    by_company = {}
    for p, pts in scored:
        company = str(p.get("company", "") or "")
        by_company.setdefault(company, []).append((p, pts))

    result = {}
    for company, company_rows in by_company.items():
        count = len(company_rows)
        for pos, (p, pts) in enumerate(company_rows, start=1):
            username = str(p["username"])
            if username not in wanted:
                continue
            if bool(p.get("is_admin", False)):
                key, title = "admin", "Admin"
            elif int(p.get("honor", 0) or 0) < 0:
                key, title = "traitor", "Vatan Haini"
            else:
                key, title = _normal_rank_for_position(pos, count)
            result[username] = {
                "rank_key": key,
                "rank_title": title,
                "rank_points": round(pts, 2),
                "company_position": pos
            }
    return result


# ============================================================
# NOVAGATE CLAN SYSTEM V1
# ============================================================
import json as _clan_json
from datetime import datetime as _clan_datetime, timezone as _clan_timezone


CLAN_DEFAULT_PERMISSIONS = {
    "Lider": {
        "applications": True, "kick": True, "roles": True, "diplomacy": True,
        "war": True, "treasury": True, "tax": True, "news": True, "invite": True
    },
    "Subay": {
        "applications": True, "kick": True, "roles": False, "diplomacy": True,
        "war": False, "treasury": False, "tax": False, "news": True, "invite": True
    },
    "Üye": {
        "applications": False, "kick": False, "roles": False, "diplomacy": False,
        "war": False, "treasury": False, "tax": False, "news": False, "invite": False
    }
}


def _clan_role_permissions(cursor, clan_id, role_name):
    cursor.execute(
        "SELECT permissions FROM clan_roles WHERE clan_id=%s AND name=%s",
        (clan_id, role_name)
    )
    row = cursor.fetchone()
    if not row:
        return {}
    value = row["permissions"] or {}
    if isinstance(value, str):
        try:
            value = _clan_json.loads(value)
        except Exception:
            value = {}
    return dict(value)


def get_clan_for_username(username):
    db = connect()
    c = db.cursor()
    c.execute("""
        SELECT cl.*, cm.role_name
        FROM clan_members cm
        JOIN clans cl ON cl.id=cm.clan_id
        WHERE cm.username=%s
    """, (username,))
    row = c.fetchone()
    c.close()
    db.close()
    return row


def get_clan_tag_for_username(username):
    row = get_clan_for_username(username)
    return str(row["tag"]) if row else ""


def get_clan_tags_for_usernames(usernames):
    names = [str(x) for x in usernames if str(x)]
    if not names:
        return {}
    db = connect()
    c = db.cursor()
    c.execute("""
        SELECT cm.username, cl.tag
        FROM clan_members cm
        JOIN clans cl ON cl.id=cm.clan_id
        WHERE cm.username = ANY(%s)
    """, (names,))
    rows = c.fetchall()
    c.close()
    db.close()
    return {str(r["username"]): str(r["tag"]) for r in rows}


def create_clan(leader_username, name, tag, description=""):
    name = str(name).strip()
    tag = str(tag).strip().upper()
    if len(name) < 3 or len(name) > 30:
        return False, "Klan adı 3-30 karakter olmalı", None
    if len(tag) < 2 or len(tag) > 5 or not tag.isalnum():
        return False, "Klan etiketi 2-5 harf/rakam olmalı", None
    if get_clan_for_username(leader_username):
        return False, "Zaten bir klandasın", None

    db = connect()
    c = db.cursor()
    try:
        c.execute("SELECT company FROM players WHERE username=%s", (leader_username,))
        player = c.fetchone()
        if not player:
            return False, "Oyuncu bulunamadı", None

        c.execute("""
            INSERT INTO clans(name,tag,leader_username,company,description)
            VALUES(%s,%s,%s,%s,%s)
            RETURNING id
        """, (name, tag, leader_username, str(player["company"] or ""), str(description)[:500]))
        clan_id = int(c.fetchone()["id"])

        for role_name, perms in CLAN_DEFAULT_PERMISSIONS.items():
            priority = 100 if role_name == "Lider" else (50 if role_name == "Subay" else 10)
            c.execute("""
                INSERT INTO clan_roles(clan_id,name,priority,permissions)
                VALUES(%s,%s,%s,%s::jsonb)
                ON CONFLICT(clan_id,name) DO NOTHING
            """, (clan_id, role_name, priority, _clan_json.dumps(perms)))

        c.execute("""
            INSERT INTO clan_members(clan_id,username,role_name)
            VALUES(%s,%s,'Lider')
        """, (clan_id, leader_username))
        db.commit()
        return True, "Klan oluşturuldu", clan_id
    except Exception as exc:
        db.rollback()
        msg = str(exc)
        if "unique" in msg.lower():
            return False, "Bu klan adı veya etiketi kullanımda", None
        raise
    finally:
        c.close()
        db.close()


def search_clans(query="", limit=30):
    db = connect()
    c = db.cursor()
    q = "%" + str(query).strip() + "%"
    c.execute("""
        SELECT cl.*,
               (SELECT COUNT(*) FROM clan_members cm WHERE cm.clan_id=cl.id) AS member_count
        FROM clans cl
        WHERE cl.name ILIKE %s OR cl.tag ILIKE %s
        ORDER BY member_count DESC, cl.id ASC
        LIMIT %s
    """, (q, q, max(1, min(int(limit), 100))))
    rows = c.fetchall()
    c.close()
    db.close()
    return rows


def get_clan_full(clan_id, viewer_username=""):
    db = connect()
    c = db.cursor()
    c.execute("""
        SELECT cl.*,
               (SELECT COUNT(*) FROM clan_members cm WHERE cm.clan_id=cl.id) AS member_count
        FROM clans cl WHERE cl.id=%s
    """, (int(clan_id),))
    clan = c.fetchone()
    if not clan:
        c.close(); db.close(); return None

    c.execute("""
        SELECT cm.username, cm.role_name, cm.joined_at,
               p.nickname, p.company, p.last_seen, p.level, p.honor
        FROM clan_members cm
        JOIN players p ON p.username=cm.username
        WHERE cm.clan_id=%s
        ORDER BY CASE WHEN cm.role_name='Lider' THEN 0 WHEN cm.role_name='Subay' THEN 1 ELSE 2 END,
                 p.nickname
    """, (int(clan_id),))
    members = [dict(r) for r in c.fetchall()]

    c.execute("""
        SELECT id,username,message,status,created_at
        FROM clan_applications
        WHERE clan_id=%s AND status='pending'
        ORDER BY created_at
    """, (int(clan_id),))
    applications = [dict(r) for r in c.fetchall()]

    c.execute("""
        SELECT cd.*, c2.name AS target_name, c2.tag AS target_tag
        FROM clan_diplomacy cd
        JOIN clans c2 ON c2.id=cd.target_clan_id
        WHERE cd.clan_id=%s
        ORDER BY cd.created_at DESC
    """, (int(clan_id),))
    diplomacy = [dict(r) for r in c.fetchall()]

    c.execute("""
        SELECT username,message,created_at
        FROM clan_messages
        WHERE clan_id=%s
        ORDER BY id DESC LIMIT 50
    """, (int(clan_id),))
    messages = [dict(r) for r in c.fetchall()]

    viewer_role = ""
    viewer_permissions = {}
    if viewer_username:
        c.execute(
            "SELECT role_name FROM clan_members WHERE clan_id=%s AND username=%s",
            (int(clan_id), viewer_username)
        )
        r = c.fetchone()
        if r:
            viewer_role = str(r["role_name"])
            viewer_permissions = _clan_role_permissions(c, int(clan_id), viewer_role)

    c.close()
    db.close()
    return {
        "clan": dict(clan),
        "members": members,
        "applications": applications,
        "diplomacy": diplomacy,
        "messages": messages,
        "viewer_role": viewer_role,
        "permissions": viewer_permissions
    }


def apply_to_clan(username, clan_id, message=""):
    if get_clan_for_username(username):
        return False, "Zaten bir klandasın"
    db = connect(); c = db.cursor()
    try:
        c.execute("""
            INSERT INTO clan_applications(clan_id,username,message,status)
            VALUES(%s,%s,%s,'pending')
            ON CONFLICT(clan_id,username)
            DO UPDATE SET message=EXCLUDED.message,status='pending',created_at=NOW()
        """, (int(clan_id), username, str(message)[:300]))
        db.commit()
        return True, "Başvuru gönderildi"
    finally:
        c.close(); db.close()


def _clan_has_permission(cursor, actor_username, clan_id, permission):
    cursor.execute(
        "SELECT role_name FROM clan_members WHERE clan_id=%s AND username=%s",
        (int(clan_id), actor_username)
    )
    row = cursor.fetchone()
    if not row:
        return False
    perms = _clan_role_permissions(cursor, int(clan_id), str(row["role_name"]))
    return bool(perms.get(permission, False))


def decide_clan_application(actor_username, application_id, accept):
    db = connect(); c = db.cursor()
    try:
        c.execute("SELECT * FROM clan_applications WHERE id=%s", (int(application_id),))
        app = c.fetchone()
        if not app:
            return False, "Başvuru bulunamadı"
        clan_id = int(app["clan_id"])
        if not _clan_has_permission(c, actor_username, clan_id, "applications"):
            return False, "Yetkin yok"
        if accept:
            c.execute("SELECT 1 FROM clan_members WHERE username=%s", (app["username"],))
            if c.fetchone():
                return False, "Oyuncu zaten bir klanda"
            c.execute(
                "INSERT INTO clan_members(clan_id,username,role_name) VALUES(%s,%s,'Üye')",
                (clan_id, app["username"])
            )
            status = "accepted"
        else:
            status = "rejected"
        c.execute("UPDATE clan_applications SET status=%s WHERE id=%s", (status, int(application_id)))
        db.commit()
        return True, "Başvuru güncellendi"
    finally:
        c.close(); db.close()


def leave_clan(username):
    clan = get_clan_for_username(username)
    if not clan:
        return False, "Bir klanda değilsin"
    clan_id = int(clan["id"])
    if str(clan["leader_username"]) == username:
        return False, "Lider klanı terk edemez; önce liderliği devret"
    db = connect(); c = db.cursor()
    c.execute("DELETE FROM clan_members WHERE clan_id=%s AND username=%s", (clan_id, username))
    db.commit(); c.close(); db.close()
    return True, "Klandan ayrıldın"


def kick_clan_member(actor_username, target_username):
    clan = get_clan_for_username(actor_username)
    if not clan:
        return False, "Klan bulunamadı"
    clan_id = int(clan["id"])
    if target_username == str(clan["leader_username"]):
        return False, "Lider çıkarılamaz"
    db = connect(); c = db.cursor()
    try:
        if not _clan_has_permission(c, actor_username, clan_id, "kick"):
            return False, "Yetkin yok"
        c.execute(
            "DELETE FROM clan_members WHERE clan_id=%s AND username=%s",
            (clan_id, target_username)
        )
        changed = c.rowcount
        db.commit()
        return (changed > 0, "Üye çıkarıldı" if changed else "Üye bulunamadı")
    finally:
        c.close(); db.close()


def set_clan_member_role(actor_username, target_username, role_name):
    clan = get_clan_for_username(actor_username)
    if not clan:
        return False, "Klan bulunamadı"
    clan_id = int(clan["id"])
    db = connect(); c = db.cursor()
    try:
        if not _clan_has_permission(c, actor_username, clan_id, "roles"):
            return False, "Yetkin yok"
        c.execute(
            "SELECT 1 FROM clan_roles WHERE clan_id=%s AND name=%s",
            (clan_id, role_name)
        )
        if not c.fetchone():
            return False, "Rütbe bulunamadı"
        if target_username == str(clan["leader_username"]):
            return False, "Lider rütbesi değiştirilemez"
        c.execute(
            "UPDATE clan_members SET role_name=%s WHERE clan_id=%s AND username=%s",
            (role_name, clan_id, target_username)
        )
        db.commit()
        return (c.rowcount > 0, "Klan rütbesi güncellendi")
    finally:
        c.close(); db.close()


def set_clan_tax(actor_username, rate):
    clan = get_clan_for_username(actor_username)
    if not clan:
        return False, "Klan bulunamadı"
    clan_id = int(clan["id"])
    rate = max(0.0, min(float(rate), 5.0))
    db = connect(); c = db.cursor()
    try:
        if not _clan_has_permission(c, actor_username, clan_id, "tax"):
            return False, "Yetkin yok"
        c.execute("UPDATE clans SET tax_rate=%s WHERE id=%s", (rate, clan_id))
        db.commit()
        return True, "Klan vergisi güncellendi"
    finally:
        c.close(); db.close()


def add_clan_message(username, message):
    clan = get_clan_for_username(username)
    if not clan:
        return False, "Klan bulunamadı"
    text = str(message).strip()
    if not text:
        return False, "Mesaj boş"
    db = connect(); c = db.cursor()
    c.execute(
        "INSERT INTO clan_messages(clan_id,username,message) VALUES(%s,%s,%s)",
        (int(clan["id"]), username, text[:500])
    )
    db.commit(); c.close(); db.close()
    return True, "Mesaj gönderildi"


def request_clan_diplomacy(actor_username, target_clan_id, relation):
    relation = str(relation).upper()
    if relation not in ("ALLIANCE", "NAP", "WAR"):
        return False, "Geçersiz diplomasi"
    clan = get_clan_for_username(actor_username)
    if not clan:
        return False, "Klan bulunamadı"
    clan_id = int(clan["id"])
    target_clan_id = int(target_clan_id)
    if clan_id == target_clan_id:
        return False, "Kendi klanın hedef olamaz"
    db = connect(); c = db.cursor()
    try:
        permission = "war" if relation == "WAR" else "diplomacy"
        if not _clan_has_permission(c, actor_username, clan_id, permission):
            return False, "Yetkin yok"
        status = "active" if relation == "WAR" else "pending"
        c.execute("""
            INSERT INTO clan_diplomacy(clan_id,target_clan_id,relation,status,requested_by)
            VALUES(%s,%s,%s,%s,%s)
            ON CONFLICT(clan_id,target_clan_id,relation)
            DO UPDATE SET status=EXCLUDED.status,requested_by=EXCLUDED.requested_by,created_at=NOW()
        """, (clan_id, target_clan_id, relation, status, actor_username))
        if relation == "WAR":
            c.execute("""
                INSERT INTO clan_diplomacy(clan_id,target_clan_id,relation,status,requested_by)
                VALUES(%s,%s,'WAR','active',%s)
                ON CONFLICT(clan_id,target_clan_id,relation)
                DO UPDATE SET status='active',requested_by=EXCLUDED.requested_by,created_at=NOW()
            """, (target_clan_id, clan_id, actor_username))
        db.commit()
        return True, "Diplomasi isteği oluşturuldu"
    finally:
        c.close(); db.close()


def respond_clan_diplomacy(actor_username, source_clan_id, relation, accept):
    relation = str(relation).upper()
    clan = get_clan_for_username(actor_username)
    if not clan:
        return False, "Klan bulunamadı"
    target_clan_id = int(clan["id"])
    db = connect(); c = db.cursor()
    try:
        if not _clan_has_permission(c, actor_username, target_clan_id, "diplomacy"):
            return False, "Yetkin yok"
        status = "active" if accept else "rejected"
        c.execute("""
            UPDATE clan_diplomacy SET status=%s
            WHERE clan_id=%s AND target_clan_id=%s AND relation=%s AND status='pending'
        """, (status, int(source_clan_id), target_clan_id, relation))
        if c.rowcount <= 0:
            return False, "İstek bulunamadı"
        if accept:
            c.execute("""
                INSERT INTO clan_diplomacy(clan_id,target_clan_id,relation,status,requested_by)
                VALUES(%s,%s,%s,'active',%s)
                ON CONFLICT(clan_id,target_clan_id,relation)
                DO UPDATE SET status='active'
            """, (target_clan_id, int(source_clan_id), relation, actor_username))
        db.commit()
        return True, "Diplomasi güncellendi"
    finally:
        c.close(); db.close()


def apply_daily_clan_tax(now_ts=None):
    # DarkOrbit benzeri günlük klan vergisi: Bitcoin bakiyesinin %0-5'i.
    # last_clan_tax_at sayesinde aynı oyuncudan günde bir kez alınır.
    db = connect(); c = db.cursor()
    try:
        c.execute("""
            SELECT p.username,p.bitcoin,p.last_clan_tax_at,cm.clan_id,cl.tax_rate
            FROM players p
            JOIN clan_members cm ON cm.username=p.username
            JOIN clans cl ON cl.id=cm.clan_id
            WHERE cl.tax_rate > 0
              AND (p.last_clan_tax_at IS NULL OR p.last_clan_tax_at < NOW() - INTERVAL '24 hours')
        """)
        rows = c.fetchall()
        for r in rows:
            amount = int(max(0, int(r["bitcoin"] or 0)) * float(r["tax_rate"] or 0) / 100.0)
            if amount <= 0:
                c.execute("UPDATE players SET last_clan_tax_at=NOW() WHERE username=%s", (r["username"],))
                continue
            c.execute("UPDATE players SET bitcoin=GREATEST(0,bitcoin-%s), last_clan_tax_at=NOW() WHERE username=%s", (amount, r["username"]))
            c.execute("UPDATE clans SET treasury_bitcoin=treasury_bitcoin+%s WHERE id=%s", (amount, int(r["clan_id"])))
        db.commit()
    finally:
        c.close(); db.close()
