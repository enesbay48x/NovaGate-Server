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

# === NovaGate persistent online world v1 ===
def ensure_online_world_tables():
    db = connect(); c = db.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS player_effects(
        player_id INTEGER PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
        ema_end DOUBLE PRECISION DEFAULT 0, nukleer_end DOUBLE PRECISION DEFAULT 0,
        onluk_end DOUBLE PRECISION DEFAULT 0, enc_cooldown_end DOUBLE PRECISION DEFAULT 0,
        enc_active_end DOUBLE PRECISION DEFAULT 0, kalkan_cooldown_end DOUBLE PRECISION DEFAULT 0,
        kalkan_active_end DOUBLE PRECISION DEFAULT 0, updated_at DOUBLE PRECISION DEFAULT 0)""")
    c.execute("""CREATE TABLE IF NOT EXISTS npc_world(
        npc_id TEXT PRIMARY KEY, map TEXT NOT NULL, npc_type TEXT NOT NULL,
        pos_x DOUBLE PRECISION NOT NULL, pos_y DOUBLE PRECISION NOT NULL,
        health DOUBLE PRECISION NOT NULL, shield DOUBLE PRECISION NOT NULL DEFAULT 0,
        max_health DOUBLE PRECISION NOT NULL, move_speed DOUBLE PRECISION NOT NULL,
        passive BOOLEAN DEFAULT FALSE, alive BOOLEAN DEFAULT TRUE,
        respawn_at DOUBLE PRECISION DEFAULT 0, updated_at DOUBLE PRECISION DEFAULT 0)""")
    c.execute("""ALTER TABLE players ADD COLUMN IF NOT EXISTS last_seen DOUBLE PRECISION DEFAULT 0""")
    db.commit(); c.close(); db.close()

def update_player_presence(username, map_name, x, y, now_ts):
    db=connect(); c=db.cursor(); c.execute("UPDATE players SET map=%s,pos_x=%s,pos_y=%s,last_seen=%s WHERE username=%s",(map_name,int(x),int(y),float(now_ts),username)); changed=c.rowcount; db.commit(); c.close(); db.close(); return changed>0

def get_online_players(map_name, now_ts, exclude_username="", ttl=12.0):
    db=connect(); c=db.cursor(); c.execute("SELECT id,username,nickname,company,ship,map,pos_x,pos_y,last_seen FROM players WHERE map=%s AND last_seen >= %s AND username<>%s ORDER BY id",(map_name,float(now_ts)-ttl,exclude_username)); rows=c.fetchall(); c.close(); db.close(); return rows

def get_effects(username):
    db=connect(); c=db.cursor(); c.execute("SELECT id FROM players WHERE username=%s",(username,)); p=c.fetchone()
    if not p: c.close(); db.close(); return None
    c.execute("INSERT INTO player_effects(player_id) VALUES(%s) ON CONFLICT(player_id) DO NOTHING",(p['id'],)); db.commit(); c.execute("SELECT * FROM player_effects WHERE player_id=%s",(p['id'],)); row=c.fetchone(); c.close(); db.close(); return row

def set_effect(username, key, cooldown_end, active_end, now_ts):
    allowed={'ema':('ema_end',None),'nukleer':('nukleer_end',None),'onluk':('onluk_end',None),'enc':('enc_cooldown_end','enc_active_end'),'kalkan':('kalkan_cooldown_end','kalkan_active_end')}
    if key not in allowed: return False
    db=connect(); c=db.cursor(); c.execute("SELECT id FROM players WHERE username=%s",(username,)); p=c.fetchone()
    if not p: c.close(); db.close(); return False
    c.execute("INSERT INTO player_effects(player_id) VALUES(%s) ON CONFLICT(player_id) DO NOTHING",(p['id'],))
    cd,active=allowed[key]
    if active:
        c.execute(f"UPDATE player_effects SET {cd}=%s,{active}=%s,updated_at=%s WHERE player_id=%s",(float(cooldown_end),float(active_end),float(now_ts),p['id']))
    else:
        c.execute(f"UPDATE player_effects SET {cd}=%s,updated_at=%s WHERE player_id=%s",(float(cooldown_end),float(now_ts),p['id']))
    db.commit(); c.close(); db.close(); return True

def get_npc_world(map_name):
    db=connect(); c=db.cursor(); c.execute("SELECT * FROM npc_world WHERE map=%s ORDER BY npc_id",(map_name,)); rows=c.fetchall(); c.close(); db.close(); return rows

def upsert_npc_world(npc_id,map_name,npc_type,x,y,health,shield,max_health,move_speed,passive,alive,respawn_at,now_ts):
    db=connect(); c=db.cursor(); c.execute("""INSERT INTO npc_world(npc_id,map,npc_type,pos_x,pos_y,health,shield,max_health,move_speed,passive,alive,respawn_at,updated_at)
    VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
    ON CONFLICT(npc_id) DO UPDATE SET map=EXCLUDED.map,npc_type=EXCLUDED.npc_type,pos_x=EXCLUDED.pos_x,pos_y=EXCLUDED.pos_y,health=EXCLUDED.health,shield=EXCLUDED.shield,max_health=EXCLUDED.max_health,move_speed=EXCLUDED.move_speed,passive=EXCLUDED.passive,alive=EXCLUDED.alive,respawn_at=EXCLUDED.respawn_at,updated_at=EXCLUDED.updated_at""",(npc_id,map_name,npc_type,float(x),float(y),float(health),float(shield),float(max_health),float(move_speed),bool(passive),bool(alive),float(respawn_at),float(now_ts))); db.commit(); c.close(); db.close(); return True

def delete_map_npcs(map_name):
    db=connect(); c=db.cursor(); c.execute("DELETE FROM npc_world WHERE map=%s",(map_name,)); db.commit(); c.close(); db.close()
