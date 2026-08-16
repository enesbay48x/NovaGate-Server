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
        """, (
            username,
            password,
            nickname,
            company.strip().upper(),
            ""
        ))

        row = cursor.fetchone()
        player_id = row["id"]

        cursor.execute("""
        INSERT INTO ships(player_id, ship_name, active)
        VALUES(%s,%s,%s)
        """, (
            player_id,
            "Başlangıç Gemisi",
            1
        ))

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
    SELECT *
    FROM players
    WHERE username=%s AND password=%s
    """, (username, password))

    row = cursor.fetchone()

    cursor.close()
    db.close()
    return row


def get_player(player_id):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    SELECT *
    FROM players
    WHERE id=%s
    """, (player_id,))

    row = cursor.fetchone()

    cursor.close()
    db.close()
    return row


def get_player_by_username(username):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    SELECT *
    FROM players
    WHERE username=%s
    """, (username,))

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
    SET company=%s,
        map=%s,
        pos_x=0,
        pos_y=0
    WHERE username=%s
    """, (
        company,
        start_map,
        username
    ))

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
        UPDATE players
        SET nickname=%s
        WHERE id=%s
        """, (
            new_nickname,
            player_id
        ))

        db.commit()
        return cursor.rowcount > 0

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
    UPDATE players
    SET plt = plt + %s
    WHERE username=%s
    """, (
        amount,
        username
    ))

    changed = cursor.rowcount
    db.commit()

    cursor.close()
    db.close()

    return changed > 0


def adjust_player_economy(
    username,
    bitcoin_delta=0,
    plt_delta=0,
    xp_delta=0,
    honor_delta=0
):
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
        bitcoin_delta,
        plt_delta,
        xp_delta,
        honor_delta,
        username,
        bitcoin_delta,
        plt_delta
    ))

    changed = cursor.rowcount
    db.commit()

    cursor.close()
    db.close()

    return changed > 0
