from fastapi import FastAPI
from database import *

app = FastAPI(
    title="NovaGate Server",
    version="1.1.0"
)

# PRODUCTION: Schema zaten mevcut. Import sırasında DDL çalıştırmak Render port açılışını kilitleyebildiği için kapalı.
# Yeni schema değişikliği gerektiğinde migration ayrı çalıştırılmalı.
# create_tables()

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

EXTRA_CATALOG = {
    "DMG-B01": {"currency": "PLT", "price": 15000},
    "HP-B01": {"currency": "PLT", "price": 15000},
    "SHD-B01": {"currency": "PLT", "price": 15000},
    "XP-B01": {"currency": "PLT", "price": 15000},
    "HON-B01": {"currency": "PLT", "price": 15000},
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
        "log_disks": int(player.get("log_disks",0)),
        "skill_points": int(player.get("skill_points",0)),
        "ship": player["ship"],
        "map": player["map"] or "",
        "x": player["pos_x"],
        "y": player["pos_y"],
        "health": float(player.get("health", 400000)),
        "shield": float(player.get("shield", 0)),
        "max_health": float(player.get("max_health", 400000)),
        "max_shield": float(player.get("max_shield", 0)),
        "alive": bool(player.get("alive", True)),
        "session_active": bool(player.get("session_active", False)),
        "is_admin": bool(player.get("is_admin", False)),
        "rank": get_player_ranking(player["username"]),
        "clan_tag": get_clan_tag_for_username(player["username"]),
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


@app.post("/skill/log_disk/add")
def add_log_disk(username: str, amount: int):
    return {"basarili": add_player_log_disks(username, amount)}

@app.get("/skill/tree/{username}")
def skill_tree(username: str):
    return {"basarili": True, "skills": [dict(x) for x in get_player_skills(username)]}

@app.post("/skill/upgrade")
def skill_upgrade(username: str, skill_id: str, cost: int = 1):
    return {"basarili": upgrade_player_skill(username, skill_id, cost)}


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

    elif kind == "extra":
        item = EXTRA_CATALOG.get(item_id)
        if not item:
            return {"basarili": False, "mesaj": "Extra market kataloğunda bulunamadı"}

        success, message, balances = buy_market_item_by_username(
            username,
            "extra",
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

# === NovaGate MMO Core V2 ===
import time
import threading
from pydantic import BaseModel
from typing import List, Dict, Any

# PRODUCTION: Online-world tabloları mevcut. Import sırasında ALTER/CREATE çalıştırma.
# ensure_online_world_tables()


class PresenceBody(BaseModel):
    username: str
    map: str
    x: float
    y: float
    health: float = -1.0
    shield: float = -1.0
    max_health: float = -1.0
    max_shield: float = -1.0


class DamageStateBody(BaseModel):
    username: str
    health: float
    shield: float
    map: str
    x: float
    y: float


class PositionStateBody(BaseModel):
    username: str
    map: str
    x: float
    y: float


class LogoutBody(BaseModel):
    username: str
    map: str
    x: float
    y: float
    health: float
    shield: float


class RepairBody(BaseModel):
    username: str
    map: str
    x: float
    y: float
    health: float
    shield: float
    max_health: float
    max_shield: float


class EffectBody(BaseModel):
    username: str
    key: str
    cooldown_seconds: float
    active_seconds: float = 0.0


class NPCBody(BaseModel):
    npc_id: str
    map: str
    npc_type: str
    x: float
    y: float
    health: float
    shield: float = 0.0
    max_health: float
    max_shield: float = 0.0
    move_speed: float
    passive: bool = False
    alive: bool = True
    respawn_at: float = 0.0
    target_username: str = ""
    first_attacker_username: str = ""
    home_x: float = 0.0
    home_y: float = 0.0


class NPCBatchPayload(BaseModel):
    npcs: List[Dict[str, Any]]


class NPCClaimBody(BaseModel):
    username: str
    npc_id: str


class NPCDeadBody(BaseModel):
    npc_id: str
    map: str
    npc_type: str
    x: float
    y: float
    max_health: float
    max_shield: float = 0.0
    move_speed: float
    passive: bool = False
    respawn_at: float
    first_attacker_username: str = ""


@app.post("/world/presence")
def world_presence(body: PresenceBody):
    now = time.time()
    ok, state = update_player_presence(
        body.username, body.map, body.x, body.y, now,
        body.health, body.shield, body.max_health, body.max_shield
    )
    return {
        "basarili": ok,
        "server_time": now,
        "health": float(state["health"]) if state else body.health,
        "shield": float(state["shield"]) if state else body.shield,
        "alive": bool(state["alive"]) if state else True
    }


@app.get("/world/players/{map_name}")
def world_players(map_name: str, username: str = ""):
    now = time.time()
    rows = get_online_players(map_name, now, username)
    usernames = [r["username"] for r in rows]
    rank_map = get_rank_snapshot_for_usernames(usernames)
    clan_map = get_clan_tags_for_usernames(usernames)
    players = []
    for r in rows:
        item = dict(r)
        rank_data = rank_map.get(str(r["username"]), {})
        item["rank_key"] = rank_data.get("rank_key", "private")
        item["rank_title"] = rank_data.get("rank_title", "Er")
        item["clan_tag"] = clan_map.get(str(r["username"]), "")
        players.append(item)
    return {"server_time": now, "players": players}




@app.post("/world/player/position_state")
def world_player_position_state(body: PositionStateBody):
    now = time.time()
    ok = update_player_position_state(
        body.username, body.map, body.x, body.y, now
    )
    return {"basarili": ok, "server_time": now}

@app.post("/world/player/damage_state")
def world_player_damage_state(body: DamageStateBody):
    now = time.time()
    state = update_player_damage_state(
        body.username, body.health, body.shield,
        body.map, body.x, body.y, now
    )
    return {
        "basarili": state is not None,
        "server_time": now,
        "health": float(state["health"]) if state else body.health,
        "shield": float(state["shield"]) if state else body.shield,
        "alive": bool(state["alive"]) if state else body.health > 0
    }


@app.post("/world/logout/request")
def world_logout_request(body: LogoutBody):
    now = time.time()
    row = request_player_logout(
        body.username, body.map, body.x, body.y,
        body.health, body.shield, now
    )
    return {
        "basarili": row is not None,
        "server_time": now,
        "logout_deadline": float(row["logout_deadline"]) if row else 0,
        "combat_until": float(row["combat_until"]) if row else 0,
        "alive": bool(row["alive"]) if row else True
    }


@app.get("/world/player/state/{username}")
def world_player_state(username: str):
    now = time.time()
    row = get_player_world_state(username)
    return {
        "basarili": row is not None,
        "server_time": now,
        "player": dict(row) if row else {}
    }


@app.post("/world/player/repair")
def world_player_repair(body: RepairBody):
    now = time.time()
    ok = repair_player_world_state(
        body.username, body.map, body.x, body.y,
        body.health, body.shield, body.max_health, body.max_shield, now
    )
    return {"basarili": ok, "server_time": now}


@app.get("/effects/{username}")
def effects_get(username: str):
    now = time.time()
    row = get_effects(username)
    return {"server_time": now, "effects": dict(row) if row else {}}


@app.post("/effects/start")
def effects_start(body: EffectBody):
    now = time.time()
    cd = now + max(0.0, body.cooldown_seconds)
    active = now + max(0.0, body.active_seconds)
    ok = set_effect(body.username, body.key, cd, active, now)
    return {
        "basarili": ok,
        "server_time": now,
        "cooldown_end": cd,
        "active_end": active
    }


@app.get("/world/npcs/{map_name}")
def world_npcs(map_name: str):
    now = time.time()
    rows = get_npc_world(map_name)
    return {"server_time": now, "npcs": [dict(r) for r in rows]}


@app.post("/world/npc")
def world_npc_update(body: NPCBody):
    now = time.time()
    upsert_npc_world(
        body.npc_id, body.map, body.npc_type, body.x, body.y,
        body.health, body.shield, body.max_health, body.move_speed,
        body.passive, body.alive, body.respawn_at, now,
        body.max_shield, body.target_username, body.first_attacker_username,
        body.home_x, body.home_y
    )
    return {"basarili": True, "server_time": now}


@app.post("/world/npcs/batch")
def world_npcs_batch(payload: NPCBatchPayload):
    upsert_world_npcs_batch(payload.npcs)
    return {"basarili": True, "updated": len(payload.npcs), "server_time": time.time()}


@app.post("/world/npc/claim")
def world_npc_claim(body: NPCClaimBody):
    row = claim_npc_first_attacker(body.npc_id, body.username)
    return {
        "basarili": row is not None,
        "first_attacker_username": str(row["first_attacker_username"]) if row else "",
        "target_username": str(row["target_username"]) if row else ""
    }


@app.post("/world/npc/dead")
def world_npc_dead(body: NPCDeadBody):
    now = time.time()
    ok = mark_npc_dead(body.model_dump(), now)
    return {"basarili": ok, "server_time": now}


_world_thread_started = False
_world_thread_lock = threading.Lock()


def _world_loop():
    while True:
        try:
            world_tick_once(time.time())
        except Exception as exc:
            print("MMO WORLD TICK ERROR:", repr(exc))
        time.sleep(0.5)


@app.on_event("startup")
def start_mmo_world_loop():
    global _world_thread_started
    with _world_thread_lock:
        if _world_thread_started:
            return
        _world_thread_started = True
        threading.Thread(
            target=_world_loop,
            name="NovaGateWorldTick",
            daemon=True
        ).start()


# ============================================================
# NOVAGATE RANKING V1 API
# ============================================================

@app.get("/ranking/player/{username}")
def ranking_player(username: str):
    data = get_player_ranking(username)
    if not data:
        return {"basarili": False, "mesaj": "Oyuncu bulunamadı"}
    return {"basarili": True, "ranking": data}


@app.get("/ranking/leaderboard")
def ranking_leaderboard(limit: int = 100, company: str = ""):
    return {
        "basarili": True,
        "company": company.strip().upper(),
        "rows": get_ranking_leaderboard(limit, company)
    }


@app.post("/ranking/stat")
def ranking_stat(username: str, stat: str, amount: int = 1):
    ok = increment_rank_stat(username, stat, amount)
    if not ok:
        return {"basarili": False, "mesaj": "Oyuncu veya istatistik bulunamadı"}
    return {"basarili": True, "ranking": get_player_ranking(username)}


@app.post("/admin/rank")
def admin_rank(username: str, enabled: bool):
    # Bu endpoint A rozetini manuel olarak açıp kapatır.
    # Normal oyuncu puan/formül yoluyla admin olamaz.
    ok = set_admin_rank(username, enabled)
    if not ok:
        return {"basarili": False, "mesaj": "Oyuncu bulunamadı"}
    return {"basarili": True, "ranking": get_player_ranking(username)}


# ============================================================
# NOVAGATE CLAN SYSTEM V1 API
# ============================================================

from pydantic import BaseModel


class ClanCreateBody(BaseModel):
    username: str
    name: str
    tag: str
    description: str = ""


class ClanApplyBody(BaseModel):
    username: str
    clan_id: int
    message: str = ""


class ClanDecisionBody(BaseModel):
    username: str
    application_id: int
    accept: bool


class ClanRoleBody(BaseModel):
    username: str
    target_username: str
    role_name: str


class ClanKickBody(BaseModel):
    username: str
    target_username: str


class ClanTaxBody(BaseModel):
    username: str
    tax_rate: float


class ClanMessageBody(BaseModel):
    username: str
    message: str


class ClanDiplomacyBody(BaseModel):
    username: str
    target_clan_id: int
    relation: str


class ClanDiplomacyResponseBody(BaseModel):
    username: str
    source_clan_id: int
    relation: str
    accept: bool


@app.post("/clan/create")
def clan_create(body: ClanCreateBody):
    ok, message, clan_id = create_clan(body.username, body.name, body.tag, body.description)
    return {"basarili": ok, "mesaj": message, "clan_id": clan_id}


@app.get("/clan/me/{username}")
def clan_me(username: str):
    membership = get_clan_for_username(username)
    if not membership:
        return {"basarili": True, "in_clan": False, "clan_tag": ""}
    data = get_clan_full(int(membership["id"]), username)
    return {"basarili": True, "in_clan": True, "clan_tag": str(membership["tag"]), "data": data}


@app.get("/clan/search")
def clan_search(q: str = "", limit: int = 30):
    return {"basarili": True, "rows": [dict(r) for r in search_clans(q, limit)]}


@app.get("/clan/{clan_id}")
def clan_detail(clan_id: int, viewer: str = ""):
    data = get_clan_full(clan_id, viewer)
    if not data:
        return {"basarili": False, "mesaj": "Klan bulunamadı"}
    return {"basarili": True, "data": data}


@app.post("/clan/apply")
def clan_apply(body: ClanApplyBody):
    ok, msg = apply_to_clan(body.username, body.clan_id, body.message)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/application/decide")
def clan_application_decide(body: ClanDecisionBody):
    ok, msg = decide_clan_application(body.username, body.application_id, body.accept)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/leave")
def clan_leave(username: str):
    ok, msg = leave_clan(username)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/kick")
def clan_kick(body: ClanKickBody):
    ok, msg = kick_clan_member(body.username, body.target_username)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/member/role")
def clan_member_role(body: ClanRoleBody):
    ok, msg = set_clan_member_role(body.username, body.target_username, body.role_name)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/tax")
def clan_tax(body: ClanTaxBody):
    ok, msg = set_clan_tax(body.username, body.tax_rate)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/message")
def clan_message(body: ClanMessageBody):
    ok, msg = add_clan_message(body.username, body.message)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/diplomacy/request")
def clan_diplomacy_request(body: ClanDiplomacyBody):
    ok, msg = request_clan_diplomacy(body.username, body.target_clan_id, body.relation)
    return {"basarili": ok, "mesaj": msg}


@app.post("/clan/diplomacy/respond")
def clan_diplomacy_respond(body: ClanDiplomacyResponseBody):
    ok, msg = respond_clan_diplomacy(body.username, body.source_clan_id, body.relation, body.accept)
    return {"basarili": ok, "mesaj": msg}
