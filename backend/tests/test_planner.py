from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from app.ics import parse_ics
from app.planner import PlanTask, plan

TZ = ZoneInfo("America/Bogota")
NOW = datetime(2026, 10, 21, 19, 30, tzinfo=TZ)


def test_plan_respects_busy_and_deadline():
    # Mañana 8-12 clase; tarea de 3 h con entrega mañana 18:00
    busy = [(datetime(2026, 10, 22, 8, 0, tzinfo=TZ), datetime(2026, 10, 22, 12, 0, tzinfo=TZ))]
    t = PlanTask(1, "Informe", 180, datetime(2026, 10, 22, 18, 0, tzinfo=TZ))
    res = plan([t], busy, NOW, TZ)
    assert sum((b.end - b.start).total_seconds() / 60 for b in res.blocks) == 180
    for b in res.blocks:
        assert not (b.start < busy[0][1] and b.end > busy[0][0])
        assert b.end <= t.deadline
    assert res.statuses[0].status in ("ok", "at_risk")


def test_plan_marks_late_when_no_time():
    t = PlanTask(1, "Enorme", 60 * 40, NOW + timedelta(days=1))
    res = plan([t], [], NOW, TZ)
    assert res.statuses[0].status == "late"
    assert res.statuses[0].unscheduled_min > 0


def test_earlier_deadline_goes_first():
    a = PlanTask(1, "tarde", 60, NOW + timedelta(days=5))
    b = PlanTask(2, "pronto", 60, NOW + timedelta(days=1))
    res = plan([a, b], [], NOW, TZ)
    assert res.blocks[0].task_id == 2


def test_done_minutes_reduce_remaining():
    t = PlanTask(1, "x", 120, NOW + timedelta(days=3), done_min=120)
    res = plan([t], [], NOW, TZ)
    assert res.blocks == [] and res.statuses[0].status == "done"


def test_sqlite_to_postgres_translation():
    from app.db import to_pg

    assert to_pg("SELECT * FROM t WHERE id=?") == ("SELECT * FROM t WHERE id=%s", False)
    assert to_pg("INSERT INTO t(a) VALUES(?)") == ("INSERT INTO t(a) VALUES(%s) RETURNING id", True)
    sql, ret = to_pg("INSERT OR IGNORE INTO t(a) VALUES(?)")
    assert sql == "INSERT INTO t(a) VALUES(%s) ON CONFLICT DO NOTHING" and not ret


ICS = b"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//test//
BEGIN:VEVENT
UID:a1
SUMMARY:Clase
DTSTART:20261022T130000Z
DTEND:20261022T150000Z
END:VEVENT
BEGIN:VEVENT
UID:a2
SUMMARY:Tarea Canvas
DESCRIPTION:Subir informe PDF en Canvas
LOCATION:Aula 204
DTSTART:20261023T050000Z
END:VEVENT
BEGIN:VEVENT
UID:a3
SUMMARY:Semanal
DTSTART:20261021T220000Z
DTEND:20261021T230000Z
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR"""


def test_parse_ics_with_recurrence_and_missing_dtend():
    evs = parse_ics(ICS, "cal", NOW - timedelta(days=1), NOW + timedelta(days=30), TZ)
    titles = [e.title for e in evs]
    assert titles.count("Semanal") == 3
    assert "Clase" in titles and "Tarea Canvas" in titles
    canvas_ev = next(e for e in evs if e.title == "Tarea Canvas")
    assert canvas_ev.description == "Subir informe PDF en Canvas"
    assert canvas_ev.location == "Aula 204"


def test_weekly_blocks_and_completed_tasks_remain_visible(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENDA_DB", str(tmp_path / "test.db"))
    from fastapi.testclient import TestClient
    from app import db
    from app.main import app

    db.init()
    c = TestClient(app)

    # Crear horario semanal de trabajo
    wb = c.post("/weekly-blocks", json={
        "title": "Jornada laboral",
        "context": "trabajo",
        "days": "1,2,3,4,5",
        "start_time": "08:00",
        "end_time": "17:00",
        "description": "Oficina / Remoto",
    })
    assert wb.status_code == 201

    # Crear tarea y marcarla como completada -> no debe desaparecer
    t = c.post("/tasks", json={
        "title": "Entrega 1",
        "context": "universidad",
        "estimate_min": 90,
        "deadline": "2026-10-25T23:59:00",
        "priority": 3,
        "description": "Detalles de la entrega",
    }).json()
    tid = t["id"]

    patched = c.patch(f"/tasks/{tid}", json={"done": True, "logged_min": 75}).json()
    assert patched["done"] is True
    assert patched["logged_min"] == 75
    assert patched["completed_at"] is not None

    all_tasks = c.get("/tasks").json()
    assert any(x["id"] == tid and x["done"] is True for x in all_tasks)

    bundle = c.get("/bundle?days=7&back=1").json()
    assert len(bundle["weekly_blocks"]) == 1
    assert any(e["calendar"] == "Horario semanal" for e in bundle["events"])
    assert any(x["id"] == tid for x in bundle["tasks"])

