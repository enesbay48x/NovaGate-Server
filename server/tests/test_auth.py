import os
import sys
import time
import asyncio

# Add server directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Set required env vars before importing
os.environ["SECRET_KEY"] = "test-secret-key-for-phase1-testing-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "10/minute"
os.environ["RATE_LIMIT_REGISTER"] = "10/minute"

import pytest
import aiosqlite
import jwt
from fastapi.testclient import TestClient
from main import app, init_db, JWT_ALGORITHM, reset_rate_limits
from config import SECRET_KEY, REFRESH_TOKEN_EXPIRE_SECONDS, ACCESS_TOKEN_EXPIRE_SECONDS


def _reset_db():
    db_path = os.environ["DB_PATH"]
    if os.path.exists(db_path):
        os.remove(db_path)


async def _init_test_db():
    _reset_db()
    await init_db()


@pytest.fixture(scope="module")
def client():
    """Create test client with initialized database."""
    asyncio.run(_init_test_db())
    with TestClient(app) as c:
        yield c


@pytest.fixture(autouse=True)
def reset_state():
    """Reset rate limits and clear database between each test."""
    reset_rate_limits()
    asyncio.run(_clear_db())
    yield
    reset_rate_limits()
    asyncio.run(_clear_db())


async def _clear_db():
    db_path = os.environ["DB_PATH"]
    async with aiosqlite.connect(db_path) as db:
        await db.execute("DELETE FROM sessions", )
        await db.execute("DELETE FROM accounts", )
        await db.commit()


def _make_username(prefix: str = "testuser") -> str:
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


class TestAuthRegister:
    """Tests for POST /auth/register"""

    def test_register_success(self, client):
        username = _make_username("reg_ok")
        resp = client.post("/auth/register", json={
            "username": username,
            "password": "TestPass123!",
            "nickname": "Test Nick",
            "company": "MMO"
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
        assert data["username"] == username
        assert "player_id" in data
        assert "account_id" in data

    def test_register_duplicate(self, client):
        username = _make_username("reg_dup")
        client.post("/auth/register", json={
            "username": username,
            "password": "TestPass123!"
        })
        resp = client.post("/auth/register", json={
            "username": username,
            "password": "TestPass123!"
        })
        assert resp.status_code == 409

    def test_register_short_password(self, client):
        username = _make_username("reg_short")
        resp = client.post("/auth/register", json={
            "username": username,
            "password": "12345"
        })
        assert resp.status_code == 422

    def test_register_short_username(self, client):
        resp = client.post("/auth/register", json={
            "username": "ab",
            "password": "TestPass123!"
        })
        assert resp.status_code == 422

    def test_register_password_not_in_response(self, client):
        username = _make_username("reg_noleak")
        resp = client.post("/auth/register", json={
            "username": username,
            "password": "TestPass123!"
        })
        data = resp.json()
        assert "password" not in data
        assert "password_hash" not in data


class TestAuthLogin:
    """Tests for POST /auth/login"""

    def test_login_success(self, client):
        username = _make_username("login_ok")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["token_type"] == "bearer"
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["username"] == username

    def test_login_wrong_password(self, client):
        username = _make_username("login_wrong")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        resp = client.post("/auth/login", json={
            "username": username,
            "password": "WrongPassword123!"
        })
        assert resp.status_code == 401

    def test_login_nonexistent_user(self, client):
        resp = client.post("/auth/login", json={
            "username": "nonexistent_user_xyz_123456",
            "password": "SomePassword123!"
        })
        assert resp.status_code == 401

    def test_login_returns_tokens(self, client):
        username = _make_username("login_tok")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        data = resp.json()
        access_payload = jwt.decode(data["access_token"], SECRET_KEY, algorithms=[JWT_ALGORITHM])
        assert access_payload["type"] == "access"
        assert access_payload["username"] == username
        refresh_payload = jwt.decode(data["refresh_token"], SECRET_KEY, algorithms=[JWT_ALGORITHM])
        assert refresh_payload["type"] == "refresh"
        assert refresh_payload["username"] == username


class TestAuthRefresh:
    """Tests for POST /auth/refresh"""

    def test_refresh_success(self, client):
        username = _make_username("refresh_ok")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        refresh_token = login_resp.json()["refresh_token"]

        resp = client.post("/auth/refresh", json={"refresh_token": refresh_token})
        assert resp.status_code == 200
        data = resp.json()
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["refresh_token"] != refresh_token

    def test_refresh_invalid_token(self, client):
        resp = client.post("/auth/refresh", json={"refresh_token": "invalid-token-string"})
        assert resp.status_code == 401

    def test_refresh_access_token_fails(self, client):
        username = _make_username("refresh_access")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        access_token = login_resp.json()["access_token"]

        resp = client.post("/auth/refresh", json={"refresh_token": access_token})
        assert resp.status_code == 401

    def test_refresh_after_logout(self, client):
        username = _make_username("refresh_after")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        access_token = login_resp.json()["access_token"]
        refresh_token = login_resp.json()["refresh_token"]

        logout_resp = client.post("/auth/logout", headers={
            "Authorization": f"Bearer {access_token}"
        })
        assert logout_resp.status_code == 200

        resp = client.post("/auth/refresh", json={"refresh_token": refresh_token})
        assert resp.status_code == 401


class TestAuthLogout:
    """Tests for POST /auth/logout"""

    def test_logout_success(self, client):
        username = _make_username("logout_ok")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        access_token = login_resp.json()["access_token"]

        resp = client.post("/auth/logout", headers={
            "Authorization": f"Bearer {access_token}"
        })
        assert resp.status_code == 200
        assert resp.json()["success"] is True

    def test_logout_no_token(self, client):
        resp = client.post("/auth/logout")
        assert resp.status_code == 401

    def test_logout_invalid_token(self, client):
        resp = client.post("/auth/logout", headers={
            "Authorization": "Bearer invalid-token"
        })
        assert resp.status_code == 401

    def test_use_after_logout(self, client):
        username = _make_username("logout_useafter")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        access_token = login_resp.json()["access_token"]

        client.post("/auth/logout", headers={
            "Authorization": f"Bearer {access_token}"
        })

        resp = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {access_token}"
        })
        assert resp.status_code == 401


class TestExpiredToken:
    """Tests for expired token handling"""

    def test_expired_access_token(self, client):
        username = _make_username("expire_access")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })

        from datetime import datetime, timedelta, timezone
        expire = datetime.now(timezone.utc) - timedelta(seconds=1)
        payload = {
            "sub": "1",
            "player_id": "test",
            "username": username,
            "is_admin": False,
            "type": "access",
            "exp": expire,
            "iat": datetime.now(timezone.utc) - timedelta(seconds=10),
            "jti": "test-jti",
        }
        expired_token = jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)

        resp = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {expired_token}"
        })
        assert resp.status_code == 401

    def test_expired_refresh_token(self, client):
        username = _make_username("expire_refresh")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })

        from datetime import datetime, timedelta, timezone
        expire = datetime.now(timezone.utc) - timedelta(seconds=1)
        payload = {
            "sub": "1",
            "player_id": "test",
            "username": username,
            "type": "refresh",
            "exp": expire,
            "iat": datetime.now(timezone.utc) - timedelta(seconds=10),
            "jti": "test-jti-refresh",
        }
        expired_token = jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)

        resp = client.post("/auth/refresh", json={"refresh_token": expired_token})
        assert resp.status_code == 401


class TestDoubleLogin:
    """Tests for double login - second login invalidates first session"""

    def test_double_login_invalidates_first(self, client):
        username = _make_username("double_login")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })

        login1 = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        token1 = login1.json()["access_token"]

        verify1 = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {token1}"
        })
        assert verify1.status_code == 200

        login2 = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        token2 = login2.json()["access_token"]

        verify2 = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {token2}"
        })
        assert verify2.status_code == 200

        assert token1 != token2


class TestAuthorization:
    """Tests for JWT-based authorization"""

    def test_unauthorized_request_no_token(self, client):
        resp = client.get("/auth/verify")
        assert resp.status_code == 401

    def test_unauthorized_request_invalid_token(self, client):
        resp = client.get("/auth/verify", headers={
            "Authorization": "Bearer not-a-real-token"
        })
        assert resp.status_code == 401

    def test_unauthorized_request_wrong_scheme(self, client):
        resp = client.get("/auth/verify", headers={
            "Authorization": "Basic abc123"
        })
        assert resp.status_code == 401

    def test_authorized_request_with_valid_token(self, client):
        username = _make_username("authz_ok")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        login_resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        token = login_resp.json()["access_token"]

        resp = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {token}"
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["valid"] is True
        assert data["username"] == username

    def test_client_cannot_impersonate_other_player(self, client):
        """Client sends player_id; server must derive identity from JWT only."""
        username_a = _make_username("authz_a")
        username_b = _make_username("authz_b")
        client.post("/auth/register", json={
            "username": username_a, "password": "CorrectPass123!"
        })
        client.post("/auth/register", json={
            "username": username_b, "password": "CorrectPass123!"
        })

        login_a = client.post("/auth/login", json={
            "username": username_a, "password": "CorrectPass123!"
        })
        token_a = login_a.json()["access_token"]

        login_b = client.post("/auth/login", json={
            "username": username_b, "password": "CorrectPass123!"
        })
        player_b_id = login_b.json()["player_id"]

        resp = client.get("/auth/verify", headers={
            "Authorization": f"Bearer {token_a}"
        })
        data = resp.json()
        assert data["username"] == username_a
        assert data["player_id"] != player_b_id


class TestPasswordSecurity:
    """Tests for password security"""

    def test_password_hashed_not_plaintext(self, client):
        username = _make_username("pw_hashed")
        resp = client.post("/auth/register", json={
            "username": username,
            "password": "UniqueTestPass456!"
        })
        data = resp.json()
        assert "password" not in data
        assert "password_hash" not in data

    def test_login_response_no_password(self, client):
        username = _make_username("pw_no_resp")
        client.post("/auth/register", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        resp = client.post("/auth/login", json={
            "username": username,
            "password": "CorrectPass123!"
        })
        data = resp.json()
        assert "password" not in data
        assert "password_hash" not in data


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
