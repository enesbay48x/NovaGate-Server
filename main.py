from fastapi import FastAPI
from database import *

app = FastAPI()

create_tables()

@app.get("/")
def home():
    return {"server":"NovaGate Server","status":"online"}

@app.post("/register")
def register(username:str, password:str, company:str):
    pid = create_player(username,password,company)
    return {"success":True,"player_id":pid}

@app.post("/login")
def login(username:str,password:str):
    player = login_player(username,password)
    if player:
        return {"success":True,"player":{
            "id":player[1],
            "username":player[2],
            "company":player[4],
            "ship_name":player[5],
            "ship_type":player[6]
        }}
    return {"success":False,"message":"Hatalı giriş"}
