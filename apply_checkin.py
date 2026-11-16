#!/usr/bin/env python3
"""Merge a dashboard check-in (from a GitHub issue body) into garmin/checkins.json.
Strict validation: the body is untrusted text, so only a date + known-safe task ids are accepted."""
import json, os, re, sys
from datetime import date, timedelta

body = os.environ.get("ISSUE_BODY", "")
try:
    obj = json.loads(body.strip())
    d = obj["date"]; ids = obj["done"]
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", d)
    day = date.fromisoformat(d)
    assert abs((day - date.today()).days) <= 7, "date out of range"
    assert isinstance(ids, list) and len(ids) <= 20
    ids = sorted({i for i in ids if isinstance(i, str) and re.fullmatch(r"[a-z0-9_]{1,40}", i)})
except Exception as e:
    print("Rejected check-in:", e); sys.exit(1)

path = "garmin/checkins.json"
try:
    store = json.load(open(path))
except Exception:
    store = {}
store[d] = {"done": ids, "via": "github-issue"}
# keep the last 60 days
cut = (date.today() - timedelta(days=60)).isoformat()
store = {k: v for k, v in store.items() if k.startswith("_") or k >= cut}
json.dump(store, open(path, "w"), indent=1)
print("Saved", d, ids)
