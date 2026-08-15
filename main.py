from fastapi import FastAPI
from database import *

app = FastAPI()


create_tables()


@app.get("/")
def home():

    return {
        "sunucu":"NovaGate Sunucusu",
        "durum":"çevrimiçi"
    }



@app.post("/register")
def register(
    username:str,
    password:str,
    company:str
):

    player_id = create_player(
        username,
        password,
        company
    )

    return {
        "basarili":True,
        "oyuncu_id":player_id
    }



@app.post("/login")
def login(
    username:str,
    password:str
):

    player = login_player(
        username,
        password
    )


    if player:

        return {
            "basarili":True,
            "oyuncu":{
                "id":player[0],
                "username":player[1],
                "company":player[3],
                "level":player[4],
                "bitcoin":player[5],
                "uridium":player[6],
                "ship":player[7],
                "map":player[8]
            }
        }


    return {
        "basarili":False,
        "mesaj":"Kullanıcı adı veya şifre yanlış"
    }



@app.get("/player/{player_id}")
def player_info(player_id:int):

    player=get_player(player_id)


    if player:

        return {
            "id":player[0],
            "username":player[1],
            "company":player[3],
            "level":player[4],
            "bitcoin":player[5],
            "uridium":player[6],
            "ship":player[7],
            "map":player[8],
            "x":player[9],
            "y":player[10]
        }


    return {
        "hata":"Oyuncu bulunamadı"
    }
