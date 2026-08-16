from fastapi import FastAPI
from database import *

app = FastAPI(
    title="NovaGate Server",
    version="1.1.0"
)

create_tables()

SHIP_CATALOG = {'Ship10': {'currency': 'FREE', 'price': 0}, 'Ship20': {'currency': 'BTC', 'price': 90000}, 'Ship40': {'currency': 'BTC', 'price': 270000}, 'Ship50': {'currency': 'BTC', 'price': 900000}, 'Ship60': {'currency': 'BTC', 'price': 2500000}, 'Ship70': {'currency': 'PLT', 'price': 90000}, 'Ship80': {'currency': 'PLT', 'price': 250000}, 'Ship100': {'currency': 'PLT', 'price': 250000}, 'Ship106': {'currency': 'PLT', 'price': 330000}}

EQUIPMENT_CATALOG = {
    "LF1": {"currency": "BTC", "price": 40000},
    "LF2": {"currency": "BTC", "price": 80000},
    "LF3": {"currency": "PLT", "price": 20000},
    "Kalkan 1": {"currency": "BTC", "price": 125000},
    "Kalkan 2": {"currency": "PLT", "price": 15000},
    "Hız 1": {"currency": "BTC", "price": 125000},
    "Hız 2": {"currency": "PLT", "price": 10000},
}

PLUS_DROID_PRICES = [100000, 200000, 400000, 800000, 1600000, 3200000, 6400000, 12800000]
ZEUS_DROID_PRICES = [12000, 20000, 35000, 60000, 100000, 170000, 300000, 500000]


def player_to_dict(player):
    if not player:
        return None

    assets = get_player_assets_by_username(player["username"])

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
        "y": player["pos_y"],
        "owned_ships": assets["owned_ships"],
        "inventory": assets["inventory"],
        "droid_types": assets["droid_types"]
    }


@app.get("/")
def home():
    return {
        "sunucu": "NovaGate Sunucusu",
        "durum": "çevrimiçi",
        "veritabani": "PostgreSQL",
        "market": "PostgreSQL aktif"
    }


@app.post("/register")
def register(username: str, password: str, nickname: str, company: str = ""):
    if get_player_by_username(username):
        return {"basarili": False, "mesaj": "Bu kullanıcı adı zaten kullanılıyor"}

    player_id = create_player(username, password, nickname, company)

    if player_id is None:
        return {"basarili": False, "mesaj": "Kayıt oluşturulamadı"}

    return {
        "basarili": True,
        "oyuncu_id": player_id,
        "mesaj": "Kayıt başarılı"
    }


@app.post("/login")
def login(username: str, password: str):
    player = login_player(username, password)
    if not player:
        return {"basarili": False, "mesaj": "Kullanıcı adı veya şifre yanlış"}

    return {
        "basarili": True,
        "oyuncu": player_to_dict(player)
    }


@app.post("/set_company")
def set_company(username: str, company: str):
    success, saved_company, start_map = set_player_company_by_username(username, company)

    if not success:
        return {
            "basarili": False,
            "mesaj": "Oyuncu bulunamadı veya şirket geçersiz"
        }

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
        return {"hata": "Oyuncu bulunamadı"}
    return player_to_dict(player)


@app.get("/player_by_username/{username}")
def player_info_by_username(username: str):
    player = get_player_by_username(username)
    if not player:
        return {"hata": "Oyuncu bulunamadı"}
    return player_to_dict(player)


@app.post("/change_nickname")
def change_player_nickname(player_id: int, new_nickname: str):
    success = change_nickname(player_id, new_nickname)
    if not success:
        return {"basarili": False, "mesaj": "Nick değiştirilemedi"}
    return {"basarili": True, "mesaj": "Nick değiştirildi"}


@app.post("/admin/add_plt")
def admin_add_plt(username: str, amount: int):
    if amount <= 0:
        return {"basarili": False, "mesaj": "PLT miktarı 0'dan büyük olmalı"}

    success = add_player_plt_by_username(username, amount)
    if not success:
        return {"basarili": False, "mesaj": "Oyuncu bulunamadı"}

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


@app.post("/economy/adjust")
def economy_adjust(
    username: str,
    bitcoin_delta: int = 0,
    plt_delta: int = 0,
    xp_delta: int = 0,
    honor_delta: int = 0
):
    success = adjust_player_economy(
        username,
        bitcoin_delta,
        plt_delta,
        xp_delta,
        honor_delta
    )

    if not success:
        return {
            "basarili": False,
            "mesaj": "Oyuncu bulunamadı veya bakiye yetersiz"
        }

    player = get_player_by_username(username)
    return {
        "basarili": True,
        "username": player["username"],
        "bitcoin": player["bitcoin"],
        "plt": player["plt"],
        "exp": player["exp"],
        "honor": player["honor"]
    }


@app.post("/market/buy")
def market_buy(username: str, kind: str, item_id: str):
    kind = kind.lower().strip()

    if kind == "ship":
        item = SHIP_CATALOG.get(item_id)
        if not item:
            return {"basarili": False, "mesaj": "Gemi market kataloğunda bulunamadı"}

        success, message, balances = buy_market_item_by_username(
            username,
            "ship",
            item_id,
            item["currency"],
            item["price"]
        )

    elif kind == "equipment":
        item = EQUIPMENT_CATALOG.get(item_id)
        if not item:
            return {"basarili": False, "mesaj": "Ekipman market kataloğunda bulunamadı"}

        success, message, balances = buy_market_item_by_username(
            username,
            "equipment",
            item_id,
            item["currency"],
            item["price"]
        )

    elif kind == "droid":
        droid_type = item_id.upper()

        if droid_type == "PLUS":
            success, message, balances = buy_droid_by_username(
                username, "PLUS", "BTC", PLUS_DROID_PRICES
            )
        elif droid_type == "ZEUS":
            success, message, balances = buy_droid_by_username(
                username, "ZEUS", "PLT", ZEUS_DROID_PRICES
            )
        else:
            return {"basarili": False, "mesaj": "Geçersiz droid türü"}
    else:
        return {"basarili": False, "mesaj": "Geçersiz market ürün tipi"}

    if not success:
        return {
            "basarili": False,
            "mesaj": message
        }

    player = get_player_by_username(username)
    assets = get_player_assets_by_username(username)

    return {
        "basarili": True,
        "mesaj": message,
        "username": username,
        "bitcoin": int(player["bitcoin"]),
        "plt": int(player["plt"]),
        "owned_ships": assets["owned_ships"],
        "inventory": assets["inventory"],
        "droid_types": assets["droid_types"]
    }
