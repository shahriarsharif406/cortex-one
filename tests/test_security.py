import pytest

from agent.security import (ConfirmationStore, LockoutTracker, PairingLocked,
                            PairingManager, RateLimiter, hash_secret,
                            sha256_hex, verify_secret)


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def test_hash_and_verify_secret():
    stored = hash_secret("4821", iterations=1000)
    assert verify_secret("4821", stored)
    assert not verify_secret("4822", stored)
    assert "4821" not in stored
    assert not verify_secret("4821", "garbage")
    assert not verify_secret("4821", "")


def test_rate_limiter_window():
    clock = Clock(0)
    rl = RateLimiter(limit=3, window=60, now=clock)
    assert [rl.allow("a") for _ in range(4)] == [True, True, True, False]
    assert rl.allow("b")  # separate key
    clock.t = 61
    assert rl.allow("a")


def test_lockout_and_expiry():
    clock = Clock(0)
    lo = LockoutTracker(max_failures=2, lockout_seconds=100, now=clock)
    lo.record_failure("x")
    assert not lo.is_locked("x")
    lo.record_failure("x")
    assert lo.is_locked("x")
    clock.t = 101
    assert not lo.is_locked("x")
    lo.record_failure("x")  # counter restarted after expiry
    assert not lo.is_locked("x")


def make_pairing(engine, clock):
    return PairingManager(engine.db, engine.settings, now=clock, lockout_now=clock)


def test_pairing_happy_path_and_token_not_stored_plain(engine):
    clock = Clock()
    pm = make_pairing(engine, clock)
    code = pm.create_code()
    token = pm.pair(code, "Shahariar's phone")
    assert token and len(token) >= 40
    dev = pm.authenticate(token)
    assert dev and dev.name == "Shahariar's phone"
    with engine.db.conn() as c:
        hashes = [r["token_hash"] for r in c.execute("SELECT token_hash FROM devices")]
        codes = [r["code_hash"] for r in c.execute("SELECT code_hash FROM pairing_codes")]
    assert hashes == [sha256_hex(token)] and token not in hashes
    assert code not in codes


def test_pairing_code_is_single_use(engine):
    pm = make_pairing(engine, Clock())
    code = pm.create_code()
    assert pm.pair(code, "a")
    assert pm.pair(code, "b") is None


def test_pairing_code_expires(engine):
    clock = Clock()
    pm = make_pairing(engine, clock)
    code = pm.create_code()
    clock.t += engine.settings.pairing_ttl_seconds + 1
    assert pm.pair(code, "late") is None


def test_pairing_lockout_blocks_even_correct_code(engine):
    pm = make_pairing(engine, Clock())
    code = pm.create_code()
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(engine.settings.max_pair_failures):
        assert pm.pair(wrong, "x") is None
    with pytest.raises(PairingLocked):
        pm.pair(code, "x")


def test_new_code_replaces_old(engine):
    pm = make_pairing(engine, Clock())
    pm.create_code()
    with engine.db.conn() as c:
        assert c.execute("SELECT COUNT(*) FROM pairing_codes").fetchone()[0] == 1
    second = pm.create_code()
    with engine.db.conn() as c:  # still exactly one active code
        assert c.execute("SELECT COUNT(*) FROM pairing_codes").fetchone()[0] == 1
    assert pm.pair(second, "x")


def test_authenticate_rejects_bad_and_revoked(engine):
    pm = make_pairing(engine, Clock())
    token = pm.pair(pm.create_code(), "phone")
    assert pm.authenticate(None) is None
    assert pm.authenticate("nope") is None
    dev = pm.authenticate(token)
    assert pm.revoke(dev.id)
    assert pm.authenticate(token) is None
    assert not pm.revoke(9999)


def test_confirmation_is_bound_single_use_and_expires():
    clock = Clock(0)
    cs = ConfirmationStore(ttl=60, now=clock)
    token = cs.issue(1, "shutdown", {})
    assert not cs.consume(token, 2, "shutdown", {})      # other device
    token = cs.issue(1, "shutdown", {})
    assert not cs.consume(token, 1, "restart", {})       # other action
    token = cs.issue(1, "run_script", {"name": "backup"})
    assert not cs.consume(token, 1, "run_script", {"name": "other"})  # other params
    token = cs.issue(1, "shutdown", {})
    assert cs.consume(token, 1, "shutdown", {})
    assert not cs.consume(token, 1, "shutdown", {})      # single use
    token = cs.issue(1, "shutdown", {})
    clock.t = 61
    assert not cs.consume(token, 1, "shutdown", {})      # expired
