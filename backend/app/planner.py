"""Motor de planificación: reparte tareas en los huecos libres del calendario."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo


@dataclass
class PlanTask:
    id: int
    title: str
    estimate_min: int
    deadline: datetime
    priority: int = 2  # 1 baja, 2 media, 3 alta
    done_min: int = 0
    context: str = "personal"


@dataclass
class Block:
    task_id: int
    title: str
    start: datetime
    end: datetime


@dataclass
class TaskStatus:
    task_id: int
    remaining_min: int
    unscheduled_min: int
    status: str  # ok | at_risk | late | done
    finish: datetime | None = None


@dataclass
class PlanResult:
    blocks: list[Block] = field(default_factory=list)
    statuses: list[TaskStatus] = field(default_factory=list)


Interval = tuple[datetime, datetime]


def merge_intervals(intervals: list[Interval]) -> list[Interval]:
    out: list[Interval] = []
    for s, e in sorted(intervals):
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def free_slots(
    busy: list[Interval],
    start: datetime,
    end: datetime,
    tz: ZoneInfo,
    day_start: time = time(8, 0),
    day_end: time = time(22, 0),
    buffer_min: int = 10,
) -> list[Interval]:
    """Huecos libres entre start y end, dentro del horario diario, restando eventos + buffer."""
    pad = timedelta(minutes=buffer_min)
    blocked = merge_intervals([(s - pad, e + pad) for s, e in busy])
    slots: list[Interval] = []
    day = start.astimezone(tz).date()
    last_day = end.astimezone(tz).date()
    while day <= last_day:
        w_start = max(datetime.combine(day, day_start, tz), start)
        w_end = min(datetime.combine(day, day_end, tz), end)
        cursor = w_start
        for bs, be in blocked:
            if be <= cursor or bs >= w_end:
                continue
            if bs > cursor:
                slots.append((cursor, bs))
            cursor = max(cursor, be)
        if cursor < w_end:
            slots.append((cursor, w_end))
        day += timedelta(days=1)
    return slots


def plan(
    tasks: list[PlanTask],
    busy: list[Interval],
    now: datetime,
    tz: ZoneInfo,
    day_start: time = time(8, 0),
    day_end: time = time(22, 0),
    max_block_min: int = 90,
    min_block_min: int = 25,
    buffer_min: int = 10,
    risk_slack_hours: int = 12,
) -> PlanResult:
    """Asigna bloques de trabajo: primero la fecha límite más cercana, luego mayor prioridad."""
    result = PlanResult()
    pending = [t for t in tasks if t.estimate_min - t.done_min > 0]
    for t in tasks:
        if t.estimate_min - t.done_min <= 0:
            result.statuses.append(TaskStatus(t.id, 0, 0, "done"))
    if not pending:
        return result

    horizon = max(t.deadline for t in pending)
    horizon = max(horizon, now + timedelta(days=1))
    slots = free_slots(busy, now, horizon, tz, day_start, day_end, buffer_min)

    for t in sorted(pending, key=lambda x: (x.deadline, -x.priority)):
        remaining = t.estimate_min - t.done_min
        left = remaining
        finish: datetime | None = None
        new_slots: list[Interval] = []
        for s, e in slots:
            if left <= 0 or s >= t.deadline:
                new_slots.append((s, e))
                continue
            usable_end = min(e, t.deadline)
            cursor = s
            while left > 0:
                avail = int((usable_end - cursor).total_seconds() // 60)
                if avail < min(min_block_min, left):
                    break
                length = min(avail, max_block_min, left)
                b_end = cursor + timedelta(minutes=length)
                result.blocks.append(Block(t.id, t.title, cursor, b_end))
                finish = b_end
                left -= length
                cursor = b_end
            if cursor < e:
                new_slots.append((cursor, e))
        slots = new_slots

        if left > 0:
            status = "late"
        elif finish and t.deadline - finish < timedelta(hours=risk_slack_hours):
            status = "at_risk"
        else:
            status = "ok"
        result.statuses.append(TaskStatus(t.id, remaining, left, status, finish))

    result.blocks.sort(key=lambda b: b.start)
    return result
