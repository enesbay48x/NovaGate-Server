import sqlite3
import random

DB="novagate.db"

def connect():
    return sqlite3.connect(DB)

def create_tables():
    db=connect()
    cur=db.cursor()
    cur.execute('''CREATE TABLE IF NOT EXISTS players(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id INTEGER UNIQUE,
    username TEXT UNIQUE,
    password TEXT,
    company TEXT,
    ship_name TEXT,
    ship_type TEXT
    )''')
    db.commit()
    db.close()

def generate_id():
    return random.randint(10000000,99999999)

def create_player(username,password,company):
    db=connect()
    cur=db.cursor()
    pid=generate_id()
    cur.execute(
    "INSERT INTO players(player_id,username,password,company,ship_name,ship_type) VALUES(?,?,?,?,?,?)",
    (pid,username,password,company,username+"_Ship","Starter"))
    db.commit()
    db.close()
    return pid

def login_player(username,password):
    db=connect()
    cur=db.cursor()
    cur.execute("SELECT * FROM players WHERE username=? AND password=?",(username,password))
    data=cur.fetchone()
    db.close()
    return data
