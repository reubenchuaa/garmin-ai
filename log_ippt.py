#!/usr/bin/env python3
"""Log an IPPT test / mock. Usage: python3 log_ippt.py <pushups> <situps> <2.4km as M:SS> [baseline|mock|official] [points]
Example: python3 log_ippt.py 38 42 10:25 baseline"""
import json, sys
from datetime import date
if len(sys.argv) < 4:
    sys.exit(__doc__)
pu, su, run = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
m, s = run.split(":"); run_sec = int(m) * 60 + int(s)
kind = sys.argv[4] if len(sys.argv) > 4 else "mock"
entry = {"date": date.today().isoformat(), "pushups": pu, "situps": su, "run_2400_sec": run_sec, "type": kind}
if len(sys.argv) > 5: entry["points"] = int(sys.argv[5])
d = json.load(open("ippt_log.json")); d["tests"].append(entry)
json.dump(d, open("ippt_log.json", "w"), indent=2)
print("Logged:", entry)
