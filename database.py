import sqlite3
from datetime import datetime

DB_NAME = "novagate.db"


def connect():
    return sqlite3.connect(DB_NAME)


def create_tables():
    conn = connect()
    cur = conn.cursor()

    cur.execute("""
    CREATE TABLE IF NOT EXISTS players(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE,
        password TEXT,
        company TEXT,
        level INTEGER DEFAULT 1,
        bitcoin INTEGER DEFAULT 0,
        uridium INTEGER DEFAULT 0,
        ship TEXT DEFAULT 'Başlangıç Gemisi',
        map TEXT DEFAULT 'x-1',
        pos_x REAL DEFAULT 0,
        pos_y REAL DEFAULT 0,
        created TEXT
    )
    """)

    conn.commit()
    conn.close()



def create_player(username,password,company):

    conn = connect()
    cur = conn.cursor()

    cur.execute("""
    INSERT INTO players
    (username,password,company,created)
    VALUES (?,?,?,?)
    """,
    (
        username,
        password,
        company,
        str(datetime.now())
    ))

    conn.commit()

    player_id = cur.lastrowid

    conn.close()

    return player_id



def login_player(username,password):

    conn = connect()
    cur = conn.cursor()

    cur.execute("""
    SELECT *
    FROM players
    WHERE username=? AND password=?
    """,
    (username,password))

    player = cur.fetchone()

    conn.close()

    return player



def get_player(player_id):

    conn = connect()
    cur = conn.cursor()

    cur.execute("""
    SELECT *
    FROM players
    WHERE id=?
    """,
    (player_id,))

    player = cur.fetchone()

    conn.close()

    return player
