"""API de Agenda personal."""
from __future__ import annotations

import os
import threading
import time as _time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel, Field

from . import db
from .ics import CalEvent, fetch_ics, parse_ics
from .planner import PlanTask, plan

TZ = ZoneInfo(os.environ.get("AGENDA_TZ", "America/Bogota"))
API_KEY = os.environ.get("AGENDA_API_KEY")  # si no se define, modo desarrollo (abierto)


def auth(request: Request, x_api_key: str | None = Header(default=None)) -> None:
    if request.url.path in ("/health", "/ping"):
        return
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(401, "API key inválida")


app = FastAPI(title="Agenda personal", dependencies=[Depends(auth)])
# Compresión GZip para acelerar respuestas grandes (/bundle y /notes) en redes móviles.
app.add_middleware(GZipMiddleware, minimum_size=500)
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


class WeeklyBlockIn(BaseModel):
    title: str
    context: str = "trabajo"
    days: str = "1,2,3,4,5"       # 1=Lun .. 7=Dom
    start_time: str = "08:00"     # HH:MM
    end_time: str = "17:00"       # HH:MM
    description: str = ""
    active: bool = True


class WeeklyBlockPatch(BaseModel):
    title: str | None = None
    context: str | None = None
    days: str | None = None
    start_time: str | None = None
    end_time: str | None = None
    description: str | None = None
    active: bool | None = None


class TaskIn(BaseModel):
    title: str
    context: str = "personal"
    estimate_min: int = Field(60, gt=0)
    deadline: datetime
    priority: int = Field(2, ge=1, le=3)
    description: str = ""


class TaskPatch(BaseModel):
    title: str | None = None
    context: str | None = None
    estimate_min: int | None = Field(None, gt=0)
    deadline: datetime | None = None
    priority: int | None = Field(None, ge=1, le=3)
    done: bool | None = None
    description: str | None = None
    logged_min: int | None = Field(None, ge=0)


class LogIn(BaseModel):
    minutes: int = Field(gt=0)


class NoteIn(BaseModel):
    title: str = ""
    body: str = ""            # texto plano de respaldo/búsqueda
    tags: str = ""
    task_id: int | None = None
    canvas: str = "[]"        # JSON con los elementos del lienzo
    color: str = "#FFF59D"
    pinned: int = Field(0, ge=0, le=1)


def _check_ctx(ctx: str) -> None:
    if ctx not in CONTEXTS:
        raise HTTPException(422, f"context debe ser uno de {sorted(CONTEXTS)}")


def _parse_hhmm(val: str) -> time:
    try:
        parts = val.strip().split(":")
        return time(int(parts[0]), int(parts[1]))
    except Exception:
        raise HTTPException(422, f"Hora inválida '{val}', usa formato HH:MM")


def _parse_days(days_str: str) -> set[int]:
    out: set[int] = set()
    for p in days_str.split(","):
        p = p.strip()
        if not p:
            continue
        d = int(p)
        if 1 <= d <= 7:
            out.add(d)
    if not out:
        raise HTTPException(422, "Selecciona al menos un día de la semana (1=Lun .. 7=Dom)")
    return out


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/ping")
def ping():
    """Consulta la base de datos y precalienta la caché de calendarios en segundo plano."""
    with db.connect() as conn:
        conn.execute("SELECT 1 AS ok").fetchone()
        cals = [dict(r) for r in conn.execute("SELECT id, name, context, url, cached_ics, cached_at FROM calendars")]
    for c in cals:
        url = c["url"]
        if url not in _cache and c.get("cached_ics"):
            _cache[url] = (float(c.get("cached_at") or 0), c["cached_ics"].encode("utf-8"))
        hit = _cache.get(url)
        if not hit or (_time.time() - hit[0]) >= CACHE_TTL:
            if url not in _refreshing:
                _refreshing.add(url)
                threading.Thread(target=_refresh_bg, args=(url, c["id"]), daemon=True).start()
    return {"ok": True, "db": True}


# ---------- calendarios ----------
@app.post("/calendars", status_code=201)
def add_calendar(c: CalendarIn):
    _check_ctx(c.context)
    with db.connect() as conn:
        cur = conn.execute("INSERT INTO calendars(name,context,url) VALUES(?,?,?)", (c.name, c.context, c.url))
        cid = cur.lastrowid
    # Pre-cargar en segundo plano el calendario recién añadido
    if c.url not in _refreshing:
        _refreshing.add(c.url)
        threading.Thread(target=_refresh_bg, args=(c.url, cid), daemon=True).start()
    return {"id": cid, **c.model_dump()}


@app.get("/calendars")
def list_calendars():
    with db.connect() as conn:
        return [dict(r) for r in conn.execute("SELECT id, name, context, url FROM calendars")]


@app.delete("/calendars/{cid}", status_code=204)
def delete_calendar(cid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM calendars WHERE id=?", (cid,))


# ---------- horario semanal fijo (trabajo / clases) ----------
def _wb_row(r) -> dict:
    d = dict(r)
    d["active"] = bool(d["active"])
    return d


@app.get("/weekly-blocks")
def list_weekly_blocks():
    with db.connect() as conn:
        return [_wb_row(r) for r in conn.execute("SELECT * FROM weekly_blocks ORDER BY start_time, id")]


@app.post("/weekly-blocks", status_code=201)
def add_weekly_block(wb: WeeklyBlockIn):
    _check_ctx(wb.context)
    t_start = _parse_hhmm(wb.start_time)
    t_end = _parse_hhmm(wb.end_time)
    if t_end <= t_start:
        raise HTTPException(422, "La hora de fin debe ser posterior a la de inicio")
    days_norm = ",".join(str(d) for d in sorted(_parse_days(wb.days)))
    with db.connect() as conn:
        cur = conn.execute(
            "INSERT INTO weekly_blocks(title,context,days,start_time,end_time,description,active) VALUES(?,?,?,?,?,?,?)",
            (wb.title.strip(), wb.context, days_norm, wb.start_time.strip(), wb.end_time.strip(), wb.description.strip(), int(wb.active)),
        )
        return _wb_row(conn.execute("SELECT * FROM weekly_blocks WHERE id=?", (cur.lastrowid,)).fetchone())


@app.patch("/weekly-blocks/{bid}")
def patch_weekly_block(bid: int, p: WeeklyBlockPatch):
    fields = p.model_dump(exclude_unset=True)
    if "context" in fields:
        _check_ctx(fields["context"])
    if "days" in fields:
        fields["days"] = ",".join(str(d) for d in sorted(_parse_days(fields["days"])))
    if "start_time" in fields:
        _parse_hhmm(fields["start_time"])
    if "end_time" in fields:
        _parse_hhmm(fields["end_time"])
    if "active" in fields:
        fields["active"] = int(fields["active"])
    if not fields:
        raise HTTPException(422, "Nada que actualizar")
    sets = ",".join(f"{k}=?" for k in fields)
    with db.connect() as conn:
        cur = conn.execute(f"UPDATE weekly_blocks SET {sets} WHERE id=?", (*fields.values(), bid))
        if cur.rowcount == 0:
            raise HTTPException(404, "Bloque semanal no existe")
        return _wb_row(conn.execute("SELECT * FROM weekly_blocks WHERE id=?", (bid,)).fetchone())


@app.delete("/weekly-blocks/{bid}", status_code=204)
def delete_weekly_block(bid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM weekly_blocks WHERE id=?", (bid,))


# ---------- caché de ICS en RAM + Base de Datos con recarga en segundo plano ----------
_cache: dict[str, tuple[float, bytes]] = {}
_refreshing: set[str] = set()
CACHE_TTL = 900        # 15 min fresco
STALE_TTL = 604800     # hasta 7 días se sirve al instante mientras se actualiza en segundo plano


def _save_ics_to_db(cal_id: int | None, url: str, data: bytes, ts: float) -> None:
    try:
        text = data.decode("utf-8", errors="ignore")
        with db.connect() as conn:
            if cal_id is not None:
                conn.execute("UPDATE calendars SET cached_ics=?, cached_at=? WHERE id=?", (text, ts, cal_id))
            else:
                conn.execute("UPDATE calendars SET cached_ics=?, cached_at=? WHERE url=?", (text, ts, url))
    except Exception:
        pass


def _refresh_bg(url: str, cal_id: int | None = None) -> None:
    try:
        data = fetch_ics(url)
        now_ts = _time.time()
        _cache[url] = (now_ts, data)
        _save_ics_to_db(cal_id, url, data, now_ts)
    except Exception:
        pass
    finally:
        _refreshing.discard(url)


def _ics_bytes(
    url: str,
    force: bool = False,
    cal_id: int | None = None,
    db_cached_ics: str | None = None,
    db_cached_at: float | None = None,
) -> bytes:
    now_ts = _time.time()
    hit = _cache.get(url)
    # Si la RAM está vacía tras un reinicio de Render, restaurar al instante desde la base de datos
    if hit is None and db_cached_ics:
        hit = (float(db_cached_at or 0), db_cached_ics.encode("utf-8"))
        _cache[url] = hit

    if not force and hit:
        age = now_ts - hit[0]
        if age < CACHE_TTL:
            return hit[1]
        if age < STALE_TTL:
            if url not in _refreshing:
                _refreshing.add(url)
                threading.Thread(target=_refresh_bg, args=(url, cal_id), daemon=True).start()
            return hit[1]
    try:
        data = fetch_ics(url)
    except Exception as e:
        if hit:
            return hit[1]
        raise HTTPException(502, f"No se pudo leer el calendario: {e}")
    _cache[url] = (now_ts, data)
    threading.Thread(target=_save_ics_to_db, args=(cal_id, url, data, now_ts), daemon=True).start()
    return data


def _expand_weekly_blocks(wbs: list[dict], start: datetime, end: datetime) -> list[tuple[CalEvent, str]]:
    out: list[tuple[CalEvent, str]] = []
    if not wbs:
        return out
    day = start.astimezone(TZ).date()
    last_day = end.astimezone(TZ).date()
    while day <= last_day:
        iso_wd = day.isoweekday()
        for wb in wbs:
            if not wb.get("active", True):
                continue
            days = {int(x) for x in str(wb.get("days", "")).split(",") if x.strip().isdigit()}
            if iso_wd not in days:
                continue
            try:
                ts = _parse_hhmm(wb["start_time"])
                te = _parse_hhmm(wb["end_time"])
            except Exception:
                continue
            dt_s = datetime.combine(day, ts, TZ)
            dt_e = datetime.combine(day, te, TZ)
            if dt_e <= start or dt_s >= end:
                continue
            out.append((
                CalEvent(
                    uid=f"wb:{wb['id']}:{day.isoformat()}",
                    title=wb["title"],
                    start=dt_s,
                    end=dt_e,
                    all_day=False,
                    source="Horario semanal",
                    description=wb.get("description", ""),
                ),
                wb.get("context", "trabajo"),
            ))
        day += timedelta(days=1)
    return out


def _load_events(
    start: datetime,
    end: datetime,
    cals: list[dict] | None = None,
    wbs: list[dict] | None = None,
    force_refresh: bool = False,
) -> list[tuple[CalEvent, str]]:
    if cals is None or wbs is None:
        with db.connect() as conn:
            if cals is None:
                cals = [dict(r) for r in conn.execute("SELECT id, name, context, url, cached_ics, cached_at FROM calendars")]
            if wbs is None:
                wbs = [_wb_row(r) for r in conn.execute("SELECT * FROM weekly_blocks WHERE active=1")]
    out: list[tuple[CalEvent, str]] = []

    def _load_one(c: dict) -> list[tuple[CalEvent, str]]:
        raw = _ics_bytes(
            c["url"],
            force=force_refresh,
            cal_id=c.get("id"),
            db_cached_ics=c.get("cached_ics"),
            db_cached_at=c.get("cached_at"),
        )
        return [(ev, c["context"]) for ev in parse_ics(raw, c["name"], start, end, TZ)]

    if len(cals) > 1:
        with ThreadPoolExecutor(max_workers=min(4, len(cals))) as ex:
            for items in ex.map(_load_one, cals):
                out.extend(items)
    elif len(cals) == 1:
        out.extend(_load_one(cals[0]))

    out.extend(_expand_weekly_blocks(wbs, start, end))
    out.sort(key=lambda x: x[0].start)
    return out


def _ev_json(ev: CalEvent, ctx: str) -> dict:
    return {
        "uid": ev.uid,
        "title": ev.title,
        "start": ev.start.isoformat(),
        "end": ev.end.isoformat(),
        "all_day": ev.all_day,
        "calendar": ev.source,
        "context": ctx,
        "url": ev.url,
        "description": ev.description,
        "location": ev.location,
    }


_BUSY_TITLES = {"busy", "ocupado", "no disponible", "unavailable"}


def _conflicts(events: list[tuple[CalEvent, str]]) -> list[dict]:
    timed = [e for e in events if not e[0].all_day and e[0].end > e[0].start]
    res = []
    for i, (a, ctx_a) in enumerate(timed):
        for b, ctx_b in timed[i + 1:]:
            if b.start >= a.end:
                break
            # Si uno es el horario semanal de trabajo y el otro un bloque "Busy/Ocupado" del calendario laboral, no es conflicto
            if ctx_a == ctx_b and (
                (a.source == "Horario semanal" and b.title.strip().lower() in _BUSY_TITLES)
                or (b.source == "Horario semanal" and a.title.strip().lower() in _BUSY_TITLES)
            ):
                continue
            res.append({"a": a.title, "b": b.title, "start": b.start.isoformat()})
    return res


@app.get("/events")
def events(days: int = 14, back: int = 0, refresh: bool = False):
    now = datetime.now(TZ)
    evs = _load_events(now - timedelta(days=back, hours=12), now + timedelta(days=days), force_refresh=refresh)
    return {"events": [_ev_json(e, c) for e, c in evs], "conflicts": _conflicts(evs)}


# ---------- tareas ----------
def _task_row(r) -> dict:
    d = dict(r)
    d["done"] = bool(d["done"])
    d.setdefault("description", "")
    d.setdefault("completed_at", None)
    return d


@app.post("/tasks", status_code=201)
def add_task(t: TaskIn):
    _check_ctx(t.context)
    dl = t.deadline if t.deadline.tzinfo else t.deadline.replace(tzinfo=TZ)
    with db.connect() as conn:
        cur = conn.execute(
            "INSERT INTO tasks(title,context,estimate_min,deadline,priority,description) VALUES(?,?,?,?,?,?)",
            (t.title.strip(), t.context, t.estimate_min, dl.isoformat(), t.priority, t.description.strip()),
        )
        row = conn.execute(
            "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min "
            "FROM tasks t WHERE t.id=?",
            (cur.lastrowid,),
        ).fetchone()
        return _task_row(row)


@app.get("/tasks")
def list_tasks(include_done: bool = True):
    q = "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min FROM tasks t"
    if not include_done:
        q += " WHERE done=0"
    with db.connect() as conn:
        return [_task_row(r) for r in conn.execute(q + " ORDER BY done ASC, deadline ASC")]


@app.patch("/tasks/{tid}")
def patch_task(tid: int, p: TaskPatch):
    fields = p.model_dump(exclude_unset=True)
    if "context" in fields:
        _check_ctx(fields["context"])
    if "deadline" in fields:
        d = fields["deadline"]
        fields["deadline"] = (d if d.tzinfo else d.replace(tzinfo=TZ)).isoformat()
    if "done" in fields:
        is_done = bool(fields["done"])
        fields["done"] = int(is_done)
        fields["completed_at"] = datetime.now(TZ).isoformat() if is_done else None
    target_logged = fields.pop("logged_min", None)
    if not fields and target_logged is None:
        raise HTTPException(422, "Nada que actualizar")
    with db.connect() as conn:
        exists = conn.execute("SELECT id FROM tasks WHERE id=?", (tid,)).fetchone()
        if not exists:
            raise HTTPException(404, "Tarea no existe")
        if fields:
            sets = ",".join(f"{k}=?" for k in fields)
            conn.execute(f"UPDATE tasks SET {sets} WHERE id=?", (*fields.values(), tid))
        if target_logged is not None:
            conn.execute("DELETE FROM time_logs WHERE task_id=?", (tid,))
            if target_logged > 0:
                conn.execute("INSERT INTO time_logs(task_id,minutes) VALUES(?,?)", (tid, target_logged))
        row = conn.execute(
            "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min "
            "FROM tasks t WHERE t.id=?",
            (tid,),
        ).fetchone()
        return _task_row(row)


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
        total = conn.execute("SELECT COALESCE(SUM(minutes),0) AS m FROM time_logs WHERE task_id=?", (tid,)).fetchone()["m"]
    return {"task_id": tid, "minutes": l.minutes, "logged_min": total}


@app.post("/calendars/{cid}/import-tasks")
def import_tasks(cid: int, days: int = 60):
    """Convierte entregas de Canvas (eventos puntuales o de todo el día) en tareas con su descripción."""
    with db.connect() as conn:
        cal = conn.execute("SELECT * FROM calendars WHERE id=?", (cid,)).fetchone()
        if not cal:
            raise HTTPException(404, "Calendario no existe")
        cal_d = dict(cal)
        now = datetime.now(TZ)
        created = 0
        updated = 0
        raw = _ics_bytes(
            cal_d["url"],
            cal_id=cal_d["id"],
            db_cached_ics=cal_d.get("cached_ics"),
            db_cached_at=cal_d.get("cached_at"),
        )
        for ev in parse_ics(raw, cal_d["name"], now - timedelta(days=7), now + timedelta(days=days), TZ):
            if not ev.all_day and ev.end > ev.start:
                continue  # es una clase/reunión con duración, no una entrega puntual
            desc_parts = [p for p in (ev.description, f"Enlace: {ev.url}" if ev.url else "") if p]
            desc = "\n\n".join(desc_parts)
            uid_key = f"{cid}:{ev.uid}"
            cur = conn.execute(
                "INSERT OR IGNORE INTO tasks(title,context,estimate_min,deadline,priority,description,source_uid) "
                "VALUES(?,?,?,?,?,?,?)",
                (ev.title, cal_d["context"], 90, ev.start.isoformat(), 2, desc, uid_key),
            )
            if cur.rowcount > 0:
                created += cur.rowcount
            elif desc:
                u = conn.execute(
                    "UPDATE tasks SET description=? WHERE source_uid=? AND (description IS NULL OR description='')",
                    (desc, uid_key),
                )
                updated += u.rowcount
    return {"imported": created, "updated": updated}


# ---------- planificador ----------
def _compute_plan(rows: list, evs: list[tuple[CalEvent, str]], now: datetime) -> dict:
    pending_rows = [r for r in rows if not r["done"]]
    tasks = [
        PlanTask(
            r["id"],
            r["title"],
            r["estimate_min"],
            datetime.fromisoformat(r["deadline"]),
            r["priority"],
            r["logged_min"],
            r["context"],
        )
        for r in pending_rows
    ]
    busy = [(e.start, e.end) for e, _ in evs if not e.all_day and e.end > e.start]
    res = plan(tasks, busy, now, TZ)
    statuses = [
        {
            "task_id": s.task_id,
            "status": s.status,
            "remaining_min": s.remaining_min,
            "unscheduled_min": s.unscheduled_min,
            "finish": s.finish.isoformat() if s.finish else None,
        }
        for s in res.statuses
    ]
    for r in rows:
        if r["done"]:
            statuses.append({
                "task_id": r["id"],
                "status": "done",
                "remaining_min": 0,
                "unscheduled_min": 0,
                "finish": r.get("completed_at"),
            })
    return {
        "blocks": [
            {"task_id": b.task_id, "title": b.title, "start": b.start.isoformat(), "end": b.end.isoformat()}
            for b in res.blocks
        ],
        "statuses": statuses,
        "conflicts": _conflicts(evs),
    }


@app.get("/plan")
def get_plan(days: int = 14):
    now = datetime.now(TZ)
    with db.connect() as conn:
        rows = [
            dict(r)
            for r in conn.execute(
                "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min "
                "FROM tasks t"
            ).fetchall()
        ]
        cals = [dict(r) for r in conn.execute("SELECT id, name, context, url, cached_ics, cached_at FROM calendars")]
        wbs = [_wb_row(r) for r in conn.execute("SELECT * FROM weekly_blocks WHERE active=1")]
    evs = _load_events(now, now + timedelta(days=days), cals=cals, wbs=wbs)
    return _compute_plan(rows, evs, now)


@app.get("/bundle")
def get_bundle(days: int = 90, back: int = 30, plan_days: int = 21, refresh: bool = False):
    """Devuelve en una sola petición rápida: eventos, horario semanal, tareas, plan y conflictos."""
    now = datetime.now(TZ)
    with db.connect() as conn:
        cals = [dict(r) for r in conn.execute("SELECT id, name, context, url, cached_ics, cached_at FROM calendars")]
        wbs = [_wb_row(r) for r in conn.execute("SELECT * FROM weekly_blocks ORDER BY start_time, id")]
        task_rows = [
            _task_row(r)
            for r in conn.execute(
                "SELECT t.*, COALESCE((SELECT SUM(minutes) FROM time_logs WHERE task_id=t.id),0) AS logged_min "
                "FROM tasks t ORDER BY done ASC, deadline ASC"
            ).fetchall()
        ]
    active_wbs = [w for w in wbs if w["active"]]
    evs = _load_events(
        now - timedelta(days=back, hours=12),
        now + timedelta(days=days),
        cals=cals,
        wbs=active_wbs,
        force_refresh=refresh,
    )
    plan_end = now + timedelta(days=plan_days)
    plan_evs = [(e, c) for e, c in evs if e.end >= now and e.start <= plan_end]
    plan_data = _compute_plan(task_rows, plan_evs, now)
    return {
        "events": [_ev_json(e, c) for e, c in evs],
        "conflicts": _conflicts(evs),
        "tasks": task_rows,
        "plan": plan_data,
        "weekly_blocks": wbs,
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
        cur = conn.execute("INSERT INTO notes(title,body,tags,task_id,canvas,color,pinned) VALUES(?,?,?,?,?,?,?)",
                           (n.title, n.body, n.tags, n.task_id, n.canvas, n.color, n.pinned))
        return dict(conn.execute("SELECT * FROM notes WHERE id=?", (cur.lastrowid,)).fetchone())


@app.get("/notes")
def list_notes(q: str | None = None, tag: str | None = None):
    """Lista ligera: no incluye el lienzo completo (puede pesar por las imágenes). Usa GET /notes/{id}."""
    sql, args = ("SELECT id,title,body,tags,task_id,color,pinned,created_at,updated_at,"
                 "LENGTH(canvas) AS canvas_size FROM notes WHERE 1=1"), []
    if q:
        sql += " AND (title LIKE ? OR body LIKE ? OR canvas LIKE ?)"
        args += [f"%{q}%", f"%{q}%", f"%{q}%"]
    if tag:
        sql += " AND (',' || tags || ',') LIKE ?"
        args.append(f"%,{tag},%")
    with db.connect() as conn:
        rows = [dict(r) for r in conn.execute(sql + " ORDER BY pinned DESC, updated_at DESC", args)]
    return rows


@app.get("/notes/{nid}")
def get_note(nid: int):
    with db.connect() as conn:
        row = conn.execute("SELECT * FROM notes WHERE id=?", (nid,)).fetchone()
    if not row:
        raise HTTPException(404, "Nota no existe")
    return dict(row)


@app.put("/notes/{nid}")
def update_note(nid: int, n: NoteIn):
    with db.connect() as conn:
        cur = conn.execute(
            "UPDATE notes SET title=?,body=?,tags=?,task_id=?,canvas=?,color=?,pinned=?,"
            "updated_at=CURRENT_TIMESTAMP WHERE id=?",
            (n.title, n.body, n.tags, n.task_id, n.canvas, n.color, n.pinned, nid))
        if cur.rowcount == 0:
            raise HTTPException(404, "Nota no existe")
        return dict(conn.execute("SELECT * FROM notes WHERE id=?", (nid,)).fetchone())


@app.delete("/notes/{nid}", status_code=204)
def delete_note(nid: int):
    with db.connect() as conn:
        conn.execute("DELETE FROM notes WHERE id=?", (nid,))
