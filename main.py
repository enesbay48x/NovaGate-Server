from fastapi import FastAPI
from database import *

app = FastAPI()

create_tables()


def player_to_dict(player):
    if not player:
        return None

    return {
        "id": player["id"],
        "username": player["username"],
        "nickname": player["nickname"],
        "company": player["company"] or "",
        "level": player["level"],
        "exp": player["exp"],
        "honor": player["honor"],
        "bitcoin": player["bitcoin"],
        "plt": player["plt"],
        "ship": player["ship"],
        "map": player["map"] or "",
        "x": player["pos_x"],
        "y": player["pos_y"]
    }


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
    company: str = ""
):
    if get_player_by_username(username):
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
def login(username: str, password: str):
    player = login_player(username, password)

    if not player:
        return {
            "basarili": False,
            "mesaj": "Kullanıcı adı veya şifre yanlış"
        }

    return {
        "basarili": True,
        "oyuncu": player_to_dict(player)
    }


@app.post("/set_company")
def set_company(username: str, company: str):
    success, saved_company, start_map = set_player_company_by_username(
        username,
        company
    )

    if not success:
        return {
            "basarili": False,
            "mesaj": "Oyuncu bulunamadı veya şirket geçersiz"
        }

    # Kaydın gerçekten veritabanına yazıldığını tekrar okuyup doğrula.
    player = get_player_by_username(username)

    return {
        "basarili": True,
        "company": player["company"],
        "map": player["map"],
        "mesaj": "Şirket kalıcı olarak kaydedildi"
    }


@app.get("/player/{player_id}")
def player_info(player_id: int):
    player = get_player(player_id)

    if not player:
        return {
            "hata": "Oyuncu bulunamadı"
        }

    return player_to_dict(player)


@app.get("/player_by_username/{username}")
def player_info_by_username(username: str):
    player = get_player_by_username(username)

    if not player:
        return {
            "hata": "Oyuncu bulunamadı"
        }

    return player_to_dict(player)


@app.post("/change_nickname")
def change_player_nickname(player_id: int, new_nickname: str):
    change_nickname(player_id, new_nickname)

    return {
        "basarili": True,
        "mesaj": "Nick değiştirildi"
    }


@app.post("/admin/add_plt")
def admin_add_plt(username: str, amount: int):
    if amount <= 0:
        return {
            "basarili": False,
            "mesaj": "PLT miktarı 0'dan büyük olmalı"
        }

    success = add_player_plt_by_username(username, amount)

    if not success:
        return {
            "basarili": False,
            "mesaj": "Oyuncu bulunamadı"
        }

    player = get_player_by_username(username)

    return {
        "basarili": True,
        "username": player["username"],
        "nickname": player["nickname"],
        "company": player["company"],
        "eklenen_plt": amount,
        "toplam_plt": player["plt"],
        "mesaj": "PLT başarıyla eklendi"
    }
