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
