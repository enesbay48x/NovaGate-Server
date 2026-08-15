import sqlite3

DB_NAME = "novagate.db"


def connect():
    return sqlite3.connect(DB_NAME)


def create_tables():
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS players(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE,
        password TEXT,
        nickname TEXT UNIQUE,
        company TEXT,
        level INTEGER DEFAULT 1,
        exp INTEGER DEFAULT 0,
        honor INTEGER DEFAULT 0,
        bitcoin INTEGER DEFAULT 0,
        plt INTEGER DEFAULT 0,
        ship TEXT DEFAULT 'Başlangıç Gemisi',
        map TEXT DEFAULT 'x-1',
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


def create_player(username, password, nickname, company):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    INSERT INTO players
    (
        username,
        password,
        nickname,
        company
    )
    VALUES(?,?,?,?)
    """, (username, password, nickname, company))

    player_id = cursor.lastrowid

    cursor.execute("""
    INSERT INTO ships
    (
        player_id,
        ship_name,
        active
    )
    VALUES(?,?,?)
    """, (player_id, "Başlangıç Gemisi", 1))

    db.commit()
    db.close()

    return player_id


def login_player(username, password):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    SELECT *
    FROM players
    WHERE username=? AND password=?
    """, (username, password))

    player = cursor.fetchone()

    db.close()
    return player


def get_player(player_id):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    SELECT *
    FROM players
    WHERE id=?
    """, (player_id,))

    player = cursor.fetchone()

    db.close()
    return player


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


def get_player_by_username(username):
    db = connect()
    cursor = db.cursor()

    cursor.execute("""
    SELECT *
    FROM players
    WHERE username=?
    """, (username,))

    player = cursor.fetchone()

    db.close()
    return player
