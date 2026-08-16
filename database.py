import sqlite3

DB_NAME = "novagate.db"


def connect():
    db = sqlite3.connect(DB_NAME, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=30000")
    return db


def create_tables():
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS players(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        nickname TEXT,
        company TEXT DEFAULT '',
        level INTEGER DEFAULT 1,
        exp INTEGER DEFAULT 0,
        honor INTEGER DEFAULT 0,
        bitcoin INTEGER DEFAULT 0,
        plt INTEGER DEFAULT 0,
        ship TEXT DEFAULT 'Başlangıç Gemisi',
        map TEXT DEFAULT '',
        pos_x INTEGER DEFAULT 0,
        pos_y INTEGER DEFAULT 0
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS inventory(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        player_id INTEGER,
        item_type TEXT,
        item_name TEXT,
        amount INTEGER DEFAULT 1
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS ships(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        player_id INTEGER,
        ship_name TEXT,
        active INTEGER DEFAULT 0
    )
    """)

    db.commit()
    db.close()


def create_player(username, password, nickname, company=""):
    db = connect()
    cursor = db.cursor()

    try:
        cursor.execute("""
        INSERT INTO players(username, password, nickname, company, map)
        VALUES(?,?,?,?,?)
        """, (username, password, nickname, company.strip().upper(), ""))

        player_id = cursor.lastrowid

        cursor.execute("""
        INSERT INTO ships(player_id, ship_name, active)
        VALUES(?,?,?)
        """, (player_id, "Başlangıç Gemisi", 1))

        db.commit()
        return player_id
    except sqlite3.IntegrityError:
        db.rollback()
        return None
    finally:
        db.close()


def login_player(username, password):
    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    SELECT * FROM players
    WHERE username=? AND password=?
    """, (username, password))
    row = cursor.fetchone()
    db.close()
    return row


def get_player(player_id):
    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players WHERE id=?", (player_id,))
    row = cursor.fetchone()
    db.close()
    return row


def get_player_by_username(username):
    db = connect()
    cursor = db.cursor()
    cursor.execute("SELECT * FROM players WHERE username=?", (username,))
    row = cursor.fetchone()
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
    SET company=?, map=?, pos_x=0, pos_y=0
    WHERE username=?
    """, (company, start_map, username))

    changed = cursor.rowcount
    db.commit()
    db.close()

    return changed > 0, company, start_map


def change_nickname(player_id, new_nickname):
    db = connect()
    cursor = db.cursor()
    cursor.execute("""
    UPDATE players
    SET nickname=?
    WHERE id=?
    """, (new_nickname, player_id))
    db.commit()
    db.close()


def add_player_plt_by_username(username, amount):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    UPDATE players
    SET plt = plt + ?
    WHERE username=?
    """, (amount, username))

    changed = cursor.rowcount
    db.commit()
    db.close()

    return changed > 0


def adjust_player_economy(username, bitcoin_delta=0, plt_delta=0, xp_delta=0, honor_delta=0):
    db = connect()
    cursor = db.cursor()

    # PLT ve Bitcoin bakiyesi negatif olamaz.
    cursor.execute("""
    UPDATE players
    SET bitcoin = bitcoin + ?,
        plt = plt + ?,
        exp = exp + ?,
        honor = honor + ?
    WHERE username = ?
      AND bitcoin + ? >= 0
      AND plt + ? >= 0
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
    db.close()

    return changed > 0
