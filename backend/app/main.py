"""API de Agenda personal."""
from __future__ import annotations

import os
import time as _time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import db
from .ics import CalEvent, fetch_ics, parse_ics
from .planner import PlanTask, plan

TZ = ZoneInfo(os.environ.get("AGENDA_TZ", "America/Bogota"))
API_KEY = os.environ.get("AGENDA_API_KEY")  # si no se define, modo desarrollo (abierto)


def auth(x_api_key: str | None = Header(default=None)) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(401, "API key inválida")


app = FastAPI(title="Agenda personal", dependencies=[Depends(auth)])
# La PWA se sirve desde otro dominio (GitHub Pages); la seguridad es la cabecera X-API-Key.
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("AGENDA_CORS", "*").split(","),
    allow_methods=["*"],
    allow_headers=["*"],
)
db.init()

CONTEXTS = {"universidad", "trabajo", "personal"}


# ---------- modelos ----------
class CalendarIn(BaseModel):
    name: str
    context: str = "personal"
    url: str


class TaskIn(BaseModel):
    title: str
    context: str = "personal"
    estimate_min: int = Field(60, gt=0)
    deadline: datetime
    priority: int = Field(2, ge=1, le=3)


class TaskPatch(BaseModel):
    title: str | None = None
    estimate_min: int | None = Field(None, gt=0)
    deadline: datetime | None = None
    priority: int | None = Field(None, ge=1, le=3)
    done: bool | None = None


class LogIn(BaseModel):
    minutes: int = Field(gt=0)


class NoteIn(BaseModel):
    title: str = ""
    body: str = ""
    tags: str = ""
    task_id: int | None = None


def _check_ctx(ctx: str) -> None:
    if ctx not in CONTEXTS:
        raise HTTPException(422, f"context debe ser uno de {sorted(CONTEXTS)}")


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/ping")
def ping():
    """Consulta la base de datos (mantiene activo el proyecto de Supabase)."""
    with db.connect() as conn:
        conn.execute("SELECT 1 AS ok").fetchone()
    return {"ok": True, "db": True}


# ---------- calendarios ----------
@app.post("/calendars", status_code=201)
def add_calendar(c: CalendarIn):
    _check_ctx(c.context)
    with db.connect() as conn:
        cur = conn.execute("INSERT INTO calendars(name,context,url) VALUES(?,?,?)", (c.name, c.context, c.url))
        return {"id": cur.lastrowid, **c.model_dump()}


@app.get("/calendars")
def list_calendars():
    with db.connect() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM calendars")]


@app.delete("/calendars/{cid}", status_code=204)
def delete_calendar(cid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM calendars WHERE id=?", (cid,))


_cache: dict[str, tuple[float, bytes]] = {}
CACHE_TTL = 300


def _ics_bytes(url: str) -> bytes:
    hit = _cache.get(url)
    if hit and _time.time() - hit[0] < CACHE_TTL:
        return hit[1]
    try:
        data = fetch_ics(url)
    except Exception as e:  # red, 404, etc.
        raise HTTPException(502, f"No se pudo leer el calendario: {e}")
    _cache[url] = (_time.time(), data)
    return data


def _load_events(start: datetime, end: datetime) -> list[tuple[CalEvent, str]]:
    with db.connect() as conn:
        cals = [dict(r) for r in conn.execute("SELECT * FROM calendars")]
    out: list[tuple[CalEvent, str]] = []
    for c in cals:
        for ev in parse_ics(_ics_bytes(c["url"]), c["name"], start, end, TZ):
            out.append((ev, c["context"]))
    out.sort(key=lambda x: x[0].start)
    return out


def _ev_json(ev: CalEvent, ctx: str) -> dict:
    return {
        "uid": ev.uid, "title": ev.title, "start": ev.start.isoformat(), "end": ev.end.isoformat(),
        "all_day": ev.all_day, "calendar": ev.source, "context": ctx, "url": ev.url,
    }


def _conflicts(events: list[tuple[CalEvent, str]]) -> list[dict]:
    timed = [e for e in events if not e[0].all_day and e[0].end > e[0].start]
    res = []
    for i, (a, _) in enumerate(timed):
        for b, _ in timed[i + 1:]:
            if b.start >= a.end:
                break
            res.append({"a": a.title, "b": b.title, "start": b.start.isoformat()})
    return res


@app.get("/events")
def events(days: int = 14):
    now = datetime.now(TZ)
    evs = _load_events(now - timedelta(hours=12), now + timedelta(days=days))
    return {"events": [_ev_json(e, c) for e, c in evs], "conflicts": _conflicts(evs)}


# ---------- tareas ----------
def _task_row(r) -> dict:
    d = dict(r)
    d["done"] = bool(d["done"])
    return d


@app.post("/tasks", status_code=201)
def add_task(t: TaskIn):
    _check_ctx(t.context)
    dl = t.deadline if t.deadline.tzinfo else t.deadline.replace(tzinfo=TZ)
    with db.connect() as conn:
        cur = conn.execute(
            "INSERT INTO tasks(title,context,estimate_min,deadline,priority) VALUES(?,?,?,?,?)",
            (t.title, t.context, t.estimate_min, dl.isoformat(), t.priority),
        )
        return _task_row(conn.execute("SELECT * FROM tasks WHERE id=?", (cur.lastrowid,)).fetchone())


@app.get("/tasks")
def list_tasks(include_done: bool = False):
    q = "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min FROM tasks t"
    if not include_done:
        q += " WHERE done=0"
    with db.connect() as conn:
        return [_task_row(r) for r in conn.execute(q + " ORDER BY deadline")]


@app.patch("/tasks/{tid}")
def patch_task(tid: int, p: TaskPatch):
    fields = p.model_dump(exclude_unset=True)
    if "deadline" in fields:
        d = fields["deadline"]
        fields["deadline"] = (d if d.tzinfo else d.replace(tzinfo=TZ)).isoformat()
    if "done" in fields:
        fields["done"] = int(fields["done"])
    if not fields:
        raise HTTPException(422, "Nada que actualizar")
    sets = ",".join(f"{k}=?" for k in fields)
    with db.connect() as conn:
        cur = conn.execute(f"UPDATE tasks SET {sets} WHERE id=?", (*fields.values(), tid))
        if cur.rowcount == 0:
            raise HTTPException(404, "Tarea no existe")
        return _task_row(conn.execute("SELECT * FROM tasks WHERE id=?", (tid,)).fetchone())


@app.delete("/tasks/{tid}", status_code=204)
def delete_task(tid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM tasks WHERE id=?", (tid,))


@app.post("/tasks/{tid}/log", status_code=201)
def log_time(tid: int, l: LogIn):
    with db.connect() as conn:
        if not conn.execute("SELECT 1 FROM tasks WHERE id=?", (tid,)).fetchone():
            raise HTTPException(404, "Tarea no existe")
        conn.execute("INSERT INTO time_logs(task_id,minutes) VALUES(?,?)", (tid, l.minutes))
    return {"task_id": tid, "minutes": l.minutes}


@app.post("/calendars/{cid}/import-tasks")
def import_tasks(cid: int, days: int = 60):
    """Convierte entregas de Canvas (eventos sin duración o de todo el día) en tareas."""
    with db.connect() as conn:
        cal = conn.execute("SELECT * FROM calendars WHERE id=?", (cid,)).fetchone()
        if not cal:
            raise HTTPException(404, "Calendario no existe")
        now = datetime.now(TZ)
        created = 0
        for ev in parse_ics(_ics_bytes(cal["url"]), cal["name"], now, now + timedelta(days=days), TZ):
            if not ev.all_day and ev.end > ev.start:
                continue  # es una clase/reunión, no una entrega
            cur = conn.execute(
                "INSERT OR IGNORE INTO tasks(title,context,estimate_min,deadline,priority,source_uid) VALUES(?,?,?,?,?,?)",
                (ev.title, cal["context"], 90, ev.start.isoformat(), 2, f"{cid}:{ev.uid}"),
            )
            created += cur.rowcount
    return {"imported": created}


# ---------- planificador ----------
@app.get("/plan")
def get_plan(days: int = 14):
    now = datetime.now(TZ)
    with db.connect() as conn:
        rows = conn.execute(
            "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged "
            "FROM tasks t WHERE done=0"
        ).fetchall()
    tasks = [
        PlanTask(r["id"], r["title"], r["estimate_min"], datetime.fromisoformat(r["deadline"]),
                 r["priority"], r["logged"], r["context"])
        for r in rows
    ]
    evs = _load_events(now, now + timedelta(days=days))
    busy = [(e.start, e.end) for e, _ in evs if not e.all_day and e.end > e.start]
    res = plan(tasks, busy, now, TZ)
    return {
        "blocks": [{"task_id": b.task_id, "title": b.title, "start": b.start.isoformat(), "end": b.end.isoformat()}
                   for b in res.blocks],
        "statuses": [{"task_id": s.task_id, "status": s.status, "remaining_min": s.remaining_min,
                      "unscheduled_min": s.unscheduled_min, "finish": s.finish.isoformat() if s.finish else None}
                     for s in res.statuses],
        "conflicts": _conflicts(evs),
    }


# ---------- estadísticas ----------
@app.get("/stats")
def stats():
    with db.connect() as conn:
        by_ctx = [dict(r) for r in conn.execute(
            "SELECT t.context, SUM(l.minutes) AS minutes FROM time_logs l JOIN tasks t ON t.id=l.task_id GROUP BY t.context")]
        acc = [dict(r) for r in conn.execute(
            "SELECT t.id, t.title, t.estimate_min, SUM(l.minutes) AS real_min FROM tasks t "
            "JOIN time_logs l ON l.task_id=t.id WHERE t.done=1 GROUP BY t.id")]
        overdue = conn.execute("SELECT COUNT(*) AS n FROM tasks WHERE done=0 AND deadline < ?",
                               (datetime.now(TZ).isoformat(),)).fetchone()["n"]
    ratio = None
    if acc:
        ratio = round(sum(a["real_min"] for a in acc) / sum(a["estimate_min"] for a in acc), 2)
    return {"minutes_by_context": by_ctx, "estimate_accuracy_ratio": ratio, "overdue_tasks": overdue}


# ---------- notas ----------
@app.post("/notes", status_code=201)
def add_note(n: NoteIn):
    with db.connect() as conn:
        cur = conn.execute("INSERT INTO notes(title,body,tags,task_id) VALUES(?,?,?,?)",
                           (n.title, n.body, n.tags, n.task_id))
        return dict(conn.execute("SELECT * FROM notes WHERE id=?", (cur.lastrowid,)).fetchone())


@app.get("/notes")
def list_notes(q: str | None = None, tag: str | None = None):
    sql, args = "SELECT * FROM notes WHERE 1=1", []
    if q:
        sql += " AND (title LIKE ? OR body LIKE ?)"
        args += [f"%{q}%", f"%{q}%"]
    if tag:
        sql += " AND (',' || tags || ',') LIKE ?"
        args.append(f"%,{tag},%")
    with db.connect() as conn:
        return [dict(r) for r in conn.execute(sql + " ORDER BY updated_at DESC", args)]


@app.put("/notes/{nid}")
def update_note(nid: int, n: NoteIn):
    with db.connect() as conn:
        cur = conn.execute(
            "UPDATE notes SET title=?,body=?,tags=?,task_id=?,updated_at=CURRENT_TIMESTAMP WHERE id=?",
            (n.title, n.body, n.tags, n.task_id, nid))
        if cur.rowcount == 0:
            raise HTTPException(404, "Nota no existe")
        return dict(conn.execute("SELECT * FROM notes WHERE id=?", (nid,)).fetchone())


@app.delete("/notes/{nid}", status_code=204)
def delete_note(nid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM notes WHERE id=?", (nid,))
