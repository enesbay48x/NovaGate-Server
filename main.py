from fastapi import FastAPI
from database import *

app = FastAPI()


# Sunucu açılışında tabloları oluşturur
create_tables()



@app.get("/")
def home():

    return {

        "sunucu": "NovaGate Sunucusu",

        "durum": "çevrimiçi"

    }





@app.post("/register")
def register(

    username: str,

    password: str,

    nickname: str,

    company: str

):


    # kullanıcı adı kontrol

    existing_user = get_player_by_username(username)


    if existing_user:

        return {

            "basarili": False,

            "mesaj": "Bu kullanıcı adı zaten kullanılıyor"

        }



    player_id = create_player(

        username,

        password,

        nickname,

        company

    )



    if player_id is None:

        return {

            "basarili": False,

            "mesaj": "Kayıt oluşturulamadı"

        }




    return {


        "basarili": True,


        "oyuncu_id": player_id,


        "mesaj": "Kayıt başarılı"


    }







@app.post("/login")
def login(

    username: str,

    password: str

):


    player = login_player(

        username,

        password

    )



    if player:


        return {


            "basarili": True,


            "oyuncu": {


                "id": player[0],


                "username": player[1],


                "nickname": player[3],


                "company": player[4],


                "level": player[5],


                "exp": player[6],


                "honor": player[7],


                "bitcoin": player[8],


                "plt": player[9],


                "ship": player[10],


                "map": player[11],


                "x": player[12],


                "y": player[13]



            }


        }




    return {


        "basarili": False,


        "mesaj": "Kullanıcı adı veya şifre yanlış"


    }








@app.get("/player/{player_id}")
def player_info(player_id:int):


    player = get_player(player_id)



    if player:


        return {


            "id": player[0],


            "username": player[1],


            "nickname": player[3],


            "company": player[4],


            "level": player[5],


            "exp": player[6],


            "honor": player[7],


            "bitcoin": player[8],


            "plt": player[9],


            "ship": player[10],


            "map": player[11],


            "x": player[12],


            "y": player[13]


        }




    return {


        "hata":"Oyuncu bulunamadı"

    }








@app.post("/change_nickname")
def change_player_nickname(

    player_id:int,

    new_nickname:str

):


    change_nickname(

        player_id,

        new_nickname

    )


    return {


        "basarili":True,


        "mesaj":"Nick değiştirildi"


    }
