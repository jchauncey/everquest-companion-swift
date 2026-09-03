#!/usr/bin/env python3
# Regenerate Sources/EQData/data/exaltations.json from eqlwiki.com.
#
# The item-inspection window in EQ Legends shows a Focus Exaltation slot; the wiki records the
# focus effects and which items carry them under Category:Focus Effects, one page per effect with
# an `items_with_effect` list and a `description` that states the tier's decay level. This scrapes
# those pages and joins each named item to our own item corpus (by an apostrophe/underscore
# tolerant name fold), writing a flat item→effect overlay the app joins at load time. It never
# edits the scraped items.json.
#
# Only focus effects are covered: worn/click/proc effects are categorized on the ITEM pages, not as
# effect pages, so they need a different pass. Run from the repo root: `python3 scripts/gen-exaltations.py`.
import json, re, subprocess, time, os, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://eqlwiki.com/api.php"
RAW = "https://eqlwiki.com/index.php"
UA = "Mozilla/5.0 EQCompanion-datagen"

def get(url):
    for _ in range(3):
        r = subprocess.run(["curl", "-s", "--max-time", "25", "-A", UA, url], capture_output=True, text=True)
        if r.stdout:
            return r.stdout
        time.sleep(1)
    return ""

def category_members(cat):
    import urllib.parse
    out, cont = [], None
    while True:
        u = f"{API}?action=query&list=categorymembers&cmtitle=Category:{urllib.parse.quote(cat)}&cmlimit=500&format=json"
        if cont:
            u += f"&cmcontinue={urllib.parse.quote(cont)}"
        d = json.loads(get(u) or "{}")
        out += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        cont = d.get("continue", {}).get("cmcontinue")
        if not cont:
            return out

def raw(title):
    import urllib.parse
    return get(f"{RAW}?title={urllib.parse.quote(title.replace(' ', '_'))}&action=raw")

def field(w, name):
    m = re.search(r'\|\s*' + re.escape(name) + r'\s*=\s*(.*?)(?=\n\s*\|\s*\w+\s*=|\n\}\})', w, re.S)
    return m.group(1).strip() if m else None

def norm(s):
    s = re.sub(r"[`'’‘]", "'", s.replace("_", " "))
    return " ".join(s.lower().split())

FAMILY = {
    "affliction efficiency": ["Mana", "DoT"], "affliction haste": ["Spell Haste", "DoT"],
    "burning affliction": ["DoT"], "enhancement haste": ["Spell Haste", "Buffs"],
    "extended enhancement": ["Buffs"], "extended range": ["Misc"],
    "improved damage": ["DD"], "improved healing": ["Healing"], "improved vampirism": ["Lifetap"],
    "mana preservation": ["Mana"], "reagent conservation": ["Misc"],
    "reanimation efficiency": ["Mana", "Pets"], "reanimation haste": ["Spell Haste", "Pets"],
    "spell haste": ["Spell Haste"], "summoning efficiency": ["Mana", "Pets"],
    "summoning haste": ["Spell Haste", "Pets"], "minion of": ["Pets"],
}

def category(effect, desc):
    base = re.sub(r"\s+(?:[IVX]+|\d+)$", "", effect).strip().lower()
    for fam, tags in FAMILY.items():
        if base.startswith(fam):
            return tags
    d = desc.lower()
    tags = []
    if "mana cost" in d:
        tags.append("Mana")
    if "cast time" in d or "casting time" in d:
        tags.append("Spell Haste")
    if "detrimental" in d and "damage" in d:
        tags.append("DoT")
    if "healing" in d:
        tags.append("Healing")
    if "pet" in d or "reanimat" in d or "summon" in d:
        tags.append("Pets")
    return tags or None

def main():
    items = json.load(open(f"{REPO}/Sources/EQData/data/items.json"))["items"]
    corpus = {norm(k): v.get("page", k) for k, v in items.items()}

    rows, unmatched = [], []
    for title in category_members("Focus Effects"):
        w = raw(title)
        if "Spellpagesmart" not in w:
            continue
        desc = re.sub(r"\s+", " ", (field(w, "description") or "")).strip()
        dm = re.search(r"over level (\d+)", desc) or re.search(r"Limit Max Level:\s*(\d+)", w)
        decay = int(dm.group(1)) if dm else None
        tags = category(title, desc)
        for it in re.findall(r"\{\{:([^}|]+)\}\}", field(w, "items_with_effect") or ""):
            page = corpus.get(norm(it))
            if not page:
                unmatched.append(it)
                continue
            row = {"item": page, "effect": title, "decaysAfter": decay}
            if tags:
                row["category"] = tags
            if desc:
                row["description"] = desc
            rows.append(row)
        time.sleep(0.15)

    seen, dedup = set(), []
    for r in sorted(rows, key=lambda r: (r["effect"], r["item"])):
        k = (r["item"].lower(), r["effect"].lower())
        if k not in seen:
            seen.add(k)
            dedup.append(r)

    doc = {
        "note": ("Item focus-effect exaltation data, scraped from eqlwiki.com Category:Focus Effects "
                 "(scripts/gen-exaltations.py). `item` is the corpus page spelling; `effect` is the focus "
                 "effect; `decaysAfter` is the level the tier's bonus decays past (null if none); `category` "
                 "is a coarse family tag; `description` is the wiki's effect text. Joined to items by name at "
                 "load time - never written into the scraped items.json."),
        "focus": dedup,
    }
    with open(f"{REPO}/Sources/EQData/data/exaltations.json", "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {len(dedup)} focus rows across {len({r['effect'] for r in dedup})} effects; "
          f"unmatched items: {sorted(set(unmatched))}", file=sys.stderr)

if __name__ == "__main__":
    main()
