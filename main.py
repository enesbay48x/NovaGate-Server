from fastapi import FastAPI
from database import *

app = FastAPI(
    title="NovaGate Server",
    version="1.0"
)


# Veritabanı tablolarını oluştur
create_tables()


@app.get("/")
def home():
    return {
        "server": "NovaGate Server",
        "status": "online"
    }


@app.post("/register")
def register(username: str, password: str, company: str):

    player_id = create_player(
        username,
        password,
        company
    )

    return {
        "success": True,
        "player_id": player_id
    }


@app.post("/login")
def login(username: str, password: str):

    player = login_player(
        username,
        password
    )

    if player:
        return {
            "success": True,
            "player": {
                "id": player[0],
                "username": player[1],
                "company": player[3]
            }
        }

    return {
        "success": False,
        "message": "Kullanıcı adı veya şifre yanlış"
    }


@app.get("/test")
def test():

    return {
        "message": "NovaGate bağlantı testi başarılı"
    }
