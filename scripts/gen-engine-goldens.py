#!/usr/bin/env python3
"""Engine-layer goldens: drive the RUST engine (engined) over its loopback socket for every fixture
and record what its VIEWS and OPS answer. The Swift EQEngine is verified against these.

For each fixture: attach, wait for the fold to land, then
  views.json      one reset per view source (default descriptor + a filtered/sorted variant each)
  ops.json        logs.list, session.health(status only), combat.searchFights, knowledge.* samples,
                  spells.search samples, resist.spell samples, perf.budgets ids
Usage: gen-engine-goldens.py <engined> <fixturesDir> <goldensDir> [--only name]
"""
import json, os, re, secrets, socket, subprocess, sys, tempfile, time, shutil, threading

BIN, FIX, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None

VIEWS = {
    "loot.ledger": [{}, {"sort": [["item", "asc"]], "window": {"offset": 5, "limit": 20}}, {"filter": {"disposition": "sold"}}],
    "combat.live": [{}, {"sort": [["name", "asc"]]}],
    "buffs.active": [{}],
    "timers.rows": [{}, {"filter": {"surface": "debuffs"}}, {"filter": {"surface": "buffs"}}],
    "respawn.watches": [{}],
    "kills.recent": [{}, {"window": {"offset": 0, "limit": 5}}],
    "progression.recent": [{}, {"filter": {"kind": "level"}}],
    "eventFeed.recent": [{}],
}
KNOWLEDGE_ITEMS = ["Mithril Earring", "Bone Chips", "Cloak of Flames", "Glowing Diamond", "Nonexistent Thing +2", "Executioners Hood +3"]
KNOWLEDGE_MOBS = ["a ghoul executioner", "Lord Nagafen", "a froglok guard", "Nobody Here", "A wan ghoul knight"]
KNOWLEDGE_SPELLS = ["Venom of the Snake", "Chloroplast", "Spirit of Wolf", "Not A Spell", "Mesmerization III"]
SEARCHES = [{"query": "mithril", "limit": 5}, {"query": "ghoul", "domain": "mob", "limit": 5}, {"query": "  "}, {"query": "spirit", "domain": "spell", "limit": 3}]
SPELL_SEARCHES = [{"text": "haste", "limit": 3}, {"classes": ["NEC"], "sort": "name", "limit": 5, "offset": 2}, {"category": "Pet", "limit": 2}]
RESIST_SPELLS = ["Venom of the Snake", "Tashani", "Nothing"]

import select

class Line:
    """A line reader over a raw socket that survives timeouts (makefile() does not)."""
    def __init__(self, sock):
        self.sock = sock; self.buf = b""
    def recv(self, timeout=None):
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line = self.buf[:nl]; self.buf = self.buf[nl + 1:]
                return json.loads(line) if line else None
            if timeout is not None:
                r, _, _ = select.select([self.sock], [], [], timeout)
                if not r: raise TimeoutError()
            chunk = self.sock.recv(1 << 16)
            if not chunk: return None
            self.buf += chunk

def run_engine():
    tok = secrets.token_hex(32)
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    p.stdin.write(tok + "\n"); p.stdin.flush()
    port = int(re.match(r"EQC-ENGINE PORT=(\d+)", p.stdout.readline()).group(1))
    s = socket.create_connection(("127.0.0.1", port)); rd = Line(s)
    def send(o): s.sendall((json.dumps(o) + "\n").encode())
    send({"op": "hello", "token": tok, "protocolVersion": 1}); rd.recv()
    return p, send, rd

def golden_for(name, log_path, character, tz_state):
    p, send, rd = run_engine()
    recv = rd.recv
    pending = {}
    nid = [10]
    def req(op, params):
        nid[0] += 1; i = nid[0]
        send({"id": i, "op": op, "params": params})
        while True:
            m = recv()
            if m is None: raise RuntimeError("engine closed")
            if m.get("kind") in ("reply", "error") and m.get("id") == i: return m
            pending.setdefault(m.get("id"), []).append(m)
    statedir = tempfile.mkdtemp(prefix="eqg-")
    # The engine answers a subscription with an immediate (possibly empty) reset and then the
    # serviced one; keep the LAST reset seen within a short quiet window.
    def last_reset(sid):
        reset = None
        for m in pending.get(sid, []):
            if m.get("kind") == "reset": reset = m
        deadline = time.time() + 0.6
        while time.time() < deadline:
            try: m = rd.recv(timeout=0.15)
            except TimeoutError:
                if reset is not None: break
                continue
            if m is None: break
            if m.get("kind") == "reset" and m.get("id") == sid: reset = m; deadline = time.time() + 0.25
            elif m.get("kind") == "diff" and m.get("id") == sid: deadline = time.time() + 0.25
            else: pending.setdefault(m.get("id"), []).append(m)
        return reset
    req("logs.setDir", {"dir": os.path.dirname(log_path)})
    ops = {"logs.list": req("logs.list", {})}
    req("session.attach", {"logPath": log_path, "stateDir": statedir})
    # wait for the scan's 100% frame, then the fold landing (health goes live only on tail; use progress)
    while True:
        m = recv()
        if m.get("kind") == "epoch" and (m.get("progress") or {}).get("pct", 0) >= 100 and not (m.get("progress") or {}).get("live"): break
        pending.setdefault(m.get("id"), []).append(m)
    # Subscribe only once the world has LANDED and the tail is running: a subscription opened in
    # the land window gets an empty reset and its rows as later diffs.
    for _ in range(100):
        h = req("session.health", {})
        if h.get("ok") and h["result"].get("status") == "live": break
        time.sleep(0.05)
    views = {}
    for src, variants in VIEWS.items():
        for k, v in enumerate(variants):
            d = {"source": src}; d.update(v)
            r = req("view.subscribe", d)
            if not r.get("ok"): views[f"{src}#{k}"] = {"descriptor": d, "error": r.get("error")}; continue
            sid = r["result"]["subscription"]
            reset = last_reset(sid)
            views[f"{src}#{k}"] = {"descriptor": d, "total": reset["total"], "rows": reset["rows"]}
            req("view.unsubscribe", {"subscription": sid})
    bad = req("view.subscribe", {"source": "nope.nothing"}); views["nope.nothing#0"] = {"descriptor": {"source": "nope.nothing"}, "error": bad.get("error")}
    bad = req("view.subscribe", {"source": "loot.ledger", "sort": [["nosuch", "asc"]]}); views["loot.ledger#badsort"] = {"error": bad.get("error")}
    ops["session.health.status"] = req("session.health", {})["result"].get("status")
    ops["combat.searchFights"] = [req("combat.searchFights", q) for q in [{"query": "ghoul", "limit": 5}, {"query": "  "}, {"query": "fire giant", "limit": 3}]]
    ops["knowledge.item"] = {n: req("knowledge.item", {"name": n}) for n in KNOWLEDGE_ITEMS}
    ops["knowledge.mob"] = {n: req("knowledge.mob", {"name": n}) for n in KNOWLEDGE_MOBS}
    ops["knowledge.spell"] = {n: req("knowledge.spell", {"name": n}) for n in KNOWLEDGE_SPELLS}
    ops["knowledge.search"] = [req("knowledge.search", q) for q in SEARCHES]
    ops["spells.search"] = [req("spells.search", q) for q in SPELL_SEARCHES]
    ops["resist.spell"] = {n: req("resist.spell", {"name": n}) for n in RESIST_SPELLS}
    ops["perf.budgets.ids"] = [b.get("id") for b in req("perf.budgets", {})["result"].get("budgets", [])]
    ops["module.snapshot.unknown"] = req("module.snapshot", {"module": "nope"})
    ops["session.mark.add"] = req("session.mark.add", {"at": 1787946132000})
    ops["alerts.define"] = req("alerts.define", {"defs": [{"id": "a1", "name": "T", "enabled": True, "trigger": {"type": "raw", "regex": "x"}, "sound": {"packId": "p", "soundId": "s"}}]})
    ops["respawn.define"] = req("respawn.define", {"prefs": {"watches": [{"key": "a froglok guard", "display": "a froglok guard"}]}})
    ops["respawn.watches.after.define"] = None
    r = req("view.subscribe", {"source": "respawn.watches"})
    if r.get("ok"):
        reset = last_reset(r["result"]["subscription"])
        ops["respawn.watches.after.define"] = {"total": reset["total"], "rows": reset["rows"]}
    # the persisted state files the engine wrote
    files = {}
    for fn in ("resist-ledger.json", "message-overlay.json"):
        fp = os.path.join(statedir, fn)
        if os.path.exists(fp):
            try: files[fn] = json.load(open(fp))
            except Exception: files[fn] = None
    ops["state.files"] = files
    p.stdin.close(); p.wait(timeout=10)
    shutil.rmtree(statedir, ignore_errors=True)
    return views, ops

os.makedirs(OUT, exist_ok=True)
stage = tempfile.mkdtemp(prefix="eqstage-")
n = 0
for f in sorted(os.listdir(FIX)):
    if not f.endswith(".log"): continue
    name = f[:-4]
    if only and only not in name: continue
    logs = os.path.join(stage, name, "Logs"); os.makedirs(logs, exist_ok=True)
    staged = os.path.join(logs, "eqlog_Primitive_freeport.txt")
    shutil.copy(os.path.join(FIX, f), staged)
    try:
        views, ops = golden_for(name, staged, "Primitive", None)
    except Exception as e:
        print("FAILED", name, e); continue
    d = os.path.join(OUT, name); os.makedirs(d, exist_ok=True)
    json.dump(views, open(os.path.join(d, "views.json"), "w"))
    json.dump(ops, open(os.path.join(d, "ops.json"), "w"))
    n += 1
print("engine goldens for", n, "fixtures")
shutil.rmtree(stage, ignore_errors=True)
