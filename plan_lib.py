#!/usr/bin/env python3
"""Daily plan + check-in logic shared by the dashboard and the coach.

- plan.json            weekly template per training phase (0=Mon..6=Sun)
- garmin/checkins.json ticks saved from the dashboard (via GitHub Action)
- Garmin activities auto-tick 'run' and 'strength' tasks
"""
import json, os
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_TYPES = {"running", "trail_running", "treadmill_running", "track_running", "ultra_running"}
STRENGTH_TYPES = {"strength_training", "hiit", "indoor_cardio", "cardio", "functional_strength_training", "calisthenics"}
REPO = "reubenchuaa/garmin-ai"


def _load(path, default):
    try:
        return json.load(open(os.path.join(HERE, path)))
    except Exception:
        return default


def sg_today():
    return (datetime.now(timezone.utc) + timedelta(hours=8)).date()


def phase_for(d, ctx):
    for ph in ctx.get("training_phases", []):
        if ph["start"] <= d.isoformat() <= ph["end"]:
            return ph["name"]
    return None


def tasks_for(d, ctx, plan=None):
    plan = plan or _load("plan.json", {})
    ph = phase_for(d, ctx)
    if ph is None:
        return None, []          # outside any planned phase: no checklist
    days = plan.get("phases", {}).get(ph, None)
    if days is None:
        return ph, plan.get("default", [])   # e.g. trip / deadline phases
    return ph, days.get(str(d.weekday()), [])


def auto_done(d, tasks, activities):
    """Task ids that Garmin can confirm for date d."""
    ds = d.isoformat()
    day = [a for a in activities if (a.get("startTimeLocal") or "")[:10] == ds]
    run_km = sum(a.get("distance", 0) for a in day if a.get("activityType", {}).get("typeKey") in RUN_TYPES) / 1000
    strength_min = sum(a.get("duration", 0) for a in day if a.get("activityType", {}).get("typeKey") in STRENGTH_TYPES) / 60
    done = []
    for t in tasks:
        if t["kind"] == "run" and run_km >= t.get("min_km", 3.0):
            done.append(t["id"])
        elif t["kind"] == "strength" and strength_min >= 15:
            done.append(t["id"])
    return done


def _checkin_done(d, checkins):
    return list((checkins.get(d.isoformat()) or {}).get("done", []))


def render(data, ctx, today=None):
    """HTML + JS block for the dashboard. Day is chosen client-side (SGT) so it never shows a stale 'today'."""
    today = today or sg_today()
    plan = _load("plan.json", {})
    checkins = _load("garmin/checkins.json", {})
    acts = data.get("activities", [])
    P, D = {}, {}
    for off in range(-1, 9):
        d = today + timedelta(days=off)
        ph, ts = tasks_for(d, ctx, plan)
        P[d.isoformat()] = {"phase": ph or "", "dow": d.strftime("%a %d %b"), "tasks": ts}
        if off <= 0:
            D[d.isoformat()] = {"auto": auto_done(d, ts, acts), "server": _checkin_done(d, checkins)}
    blob = lambda o: json.dumps(o, ensure_ascii=False).replace("</", "<\\/")
    return """
<div class="sec">Today's Plan</div>
<div class="box" id="planbox">
  <div id="plan-head" style="display:flex;justify-content:space-between;align-items:baseline;gap:8px;flex-wrap:wrap"></div>
  <div id="plan-today" style="margin-top:10px"></div>
  <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:12px">
    <button id="plan-send" style="background:#3b82f6;color:#fff;border:0;border-radius:8px;padding:9px 14px;font-size:.85rem;font-weight:600;cursor:pointer">Send check-in to coach</button>
    <span id="plan-sent" style="font-size:.75rem;color:#64748b"></span>
  </div>
  <div style="font-size:.7rem;color:#475569;margin-top:8px">Garmin runs and gym sessions tick themselves. Tick the rest as you go, then tap Send once a day (opens a GitHub page &mdash; tap Submit). Tomorrow's coach note uses it.</div>
</div>
<div class="sec">Next 7 Days</div>
<div class="box" id="plan-week" style="font-size:.82rem;line-height:1.5"></div>
<script>
(function(){
var PLAN=""" + blob(P) + """, DONE=""" + blob(D) + """, REPO='""" + REPO + """';
function sg(off){return new Date(Date.now()+8*3600*1000+off*86400000).toISOString().slice(0,10);}
var today=sg(0), key='ckv1_'+today, sentKey='cksent_'+today, local=[];
try{local=JSON.parse(localStorage.getItem(key)||'[]');}catch(e){}
function save(){try{localStorage.setItem(key,JSON.stringify(local));}catch(e){}}
var info=PLAN[today], dn=DONE[today]||{auto:[],server:[]};
var head=document.getElementById('plan-head'), box=document.getElementById('plan-today');
function esc(s){return String(s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function isDone(id){return dn.auto.indexOf(id)>-1||dn.server.indexOf(id)>-1||local.indexOf(id)>-1;}
var openSet={};
function stepsHtml(t){if(!t.steps||!t.steps.length)return '';
  return '<details data-sid="'+esc(t.id)+'"'+(openSet[t.id]?' open':'')+' style="margin:6px 0 0 30px"><summary style="cursor:pointer;font-size:.78rem;color:#60a5fa">How to do it</summary><ol style="margin:6px 0 0 18px;padding:0;font-size:.78rem;color:#cbd5e1;line-height:1.55">'
   +t.steps.map(function(x){return '<li style="margin-bottom:4px">'+esc(x)+'</li>';}).join('')+'</ol></details>';}
function draw(){
  if(!info||!info.tasks.length){head.innerHTML='<b>'+(info?esc(info.dow):'Today')+'</b><span style="font-size:.75rem;color:#94a3b8">No checklist today</span>';box.innerHTML='';return;}
  var n=0;info.tasks.forEach(function(t){if(isDone(t.id))n++;});
  head.innerHTML='<span style="font-weight:700;font-size:1rem">'+esc(info.dow)+'</span><span style="font-size:.75rem;color:#94a3b8">'+esc(info.phase)+' &middot; '+n+'/'+info.tasks.length+' done</span>';
  box.innerHTML=info.tasks.map(function(t){
    var auto=dn.auto.indexOf(t.id)>-1, on=isDone(t.id);
    return '<div style="padding:9px 0;border-top:1px solid #1e293b"><label style="display:flex;gap:10px;cursor:'+(auto?'default':'pointer')+'">'
      +'<input type="checkbox" data-id="'+esc(t.id)+'" '+(on?'checked ':'')+(auto?'disabled ':'')+'style="width:20px;height:20px;margin-top:2px;accent-color:#10b981;flex:none">'
      +'<span><span style="font-weight:600;color:'+(on?'#64748b':'#e2e8f0')+';'+(on?'text-decoration:line-through':'')+'">'+esc(t.label)+(auto?' <span style="font-size:.7rem;color:#10b981">&#10003; Garmin</span>':'')+'</span>'
      +'<span style="display:block;font-size:.76rem;color:#94a3b8">'+esc(t.detail)+'</span></span></label>'+stepsHtml(t)+'</div>';
  }).join('');
  Array.prototype.forEach.call(box.querySelectorAll('details'),function(el){
    el.ontoggle=function(){openSet[el.getAttribute('data-sid')]=el.open;};
  });
  Array.prototype.forEach.call(box.querySelectorAll('input'),function(el){
    el.onchange=function(){var id=el.getAttribute('data-id'),i=local.indexOf(id);
      if(el.checked&&i<0)local.push(id); if(!el.checked&&i>-1)local.splice(i,1); save(); draw();};
  });
}
draw();
var sent=document.getElementById('plan-sent');
try{if(localStorage.getItem(sentKey))sent.textContent='Sent ✓ (the coach reads it on its next run)';}catch(e){}
document.getElementById('plan-send').onclick=function(){
  if(!info)return;
  var ids=info.tasks.filter(function(t){return isDone(t.id);}).map(function(t){return t.id;});
  if(!ids.length){alert('Tick at least one task first.');return;}
  var body=JSON.stringify({date:today,done:ids,v:1});
  window.open('https://github.com/'+REPO+'/issues/new?title='+encodeURIComponent('checkin '+today)+'&body='+encodeURIComponent(body),'_blank');
  try{localStorage.setItem(sentKey,'1');}catch(e){}
  sent.textContent='Opened GitHub — tap "Submit new issue" to finish.';
};
var wk=document.getElementById('plan-week'),h='';
for(var o=1;o<=7;o++){var d=sg(o),p=PLAN[d];if(!p)continue;
  h+='<div style="padding:7px 0;border-top:1px solid #1e293b"><b>'+esc(p.dow)+'</b> <span style="color:#64748b;font-size:.72rem">'+esc(p.phase)+'</span><br><span style="color:#cbd5e1">'
   +p.tasks.map(function(t){return esc(t.label);}).join(' &middot; ')+'</span></div>';}
wk.innerHTML=h;
})();
</script>
"""


def coach_block(data, ctx, today=None):
    """Plain-text summary for the coach prompt: yesterday's completion + the planned checklist ahead."""
    today = today or sg_today()
    plan = _load("plan.json", {})
    checkins = _load("garmin/checkins.json", {})
    acts = data.get("activities", [])
    out = []
    for off in (-2, -1):
        d = today + timedelta(days=off)
        ph, ts = tasks_for(d, ctx, plan)
        if not ts:
            continue
        auto = set(auto_done(d, ts, acts)); manual = set(_checkin_done(d, checkins))
        done = [t["label"] for t in ts if t["id"] in auto or t["id"] in manual]
        missed = [t["label"] for t in ts if t["id"] not in auto and t["id"] not in manual]
        reported = d.isoformat() in checkins
        out.append(f"{d.strftime('%a %d %b')} ({ph}): done {len(done)}/{len(ts)}"
                   + (f" [{', '.join(done)}]" if done else "")
                   + (f"; NOT DONE: {', '.join(missed)}" if missed else "")
                   + ("" if reported else " (no manual check-in received, so non-Garmin tasks may be unreported rather than skipped)"))
    for off, name in ((0, "TODAY"), (1, "Tomorrow"), (2, "Day after")):
        d = today + timedelta(days=off)
        ph, ts = tasks_for(d, ctx, plan)
        out.append(f"{name} {d.strftime('%a %d %b')} planned checklist ({ph}): " + "; ".join(f"{t['label']}" for t in ts))
    return " | ".join(out)


if __name__ == "__main__":
    import sys
    data = _load("garmin/data.json", {"activities": []})
    ctx = _load("context.json", {})
    if len(sys.argv) > 1 and sys.argv[1] == "coach":
        print(coach_block(data, ctx))
    else:
        t = sg_today(); print(phase_for(t, ctx), [x["label"] for x in tasks_for(t, ctx)[1]])
