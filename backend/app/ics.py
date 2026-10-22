"""Lectura de calendarios ICS (Canvas, Google Calendar vía enlace secreto/público)."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import httpx
import icalendar
import recurring_ical_events

_http = httpx.Client(timeout=18, follow_redirects=True)


@dataclass
class CalEvent:
    uid: str
    title: str
    start: datetime
    end: datetime
    all_day: bool
    source: str
    url: str = ""
    description: str = ""
    location: str = ""


def _to_dt(value, tz: ZoneInfo) -> tuple[datetime, bool]:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=tz)
        else:
            value = value.astimezone(tz)
        return value, False
    if isinstance(value, date):
        return datetime.combine(value, time.min, tz), True
    raise ValueError(f"Fecha no soportada: {value!r}")


def parse_ics(data: bytes | str, source: str, start: datetime, end: datetime, tz: ZoneInfo) -> list[CalEvent]:
    cal = icalendar.Calendar.from_ical(data)
    events: list[CalEvent] = []
    for comp in recurring_ical_events.of(cal).between(start, end):
        dt_start, all_day = _to_dt(comp.get("DTSTART").dt, tz)
        if comp.get("DTEND") is not None:
            dt_end, _ = _to_dt(comp.get("DTEND").dt, tz)
        elif comp.get("DURATION") is not None:
            dt_end = dt_start + comp.get("DURATION").dt
        else:
            # Canvas publica entregas sin DTEND: se asume punto en el tiempo.
            dt_end = dt_start + (timedelta(days=1) if all_day else timedelta(minutes=0))
        events.append(
            CalEvent(
                uid=str(comp.get("UID", "")),
                title=str(comp.get("SUMMARY", "(sin título)")),
                start=dt_start,
                end=dt_end,
                all_day=all_day,
                source=source,
                url=str(comp.get("URL", "")),
                description=str(comp.get("DESCRIPTION", "")).strip(),
                location=str(comp.get("LOCATION", "")).strip(),
            )
        )
    events.sort(key=lambda e: e.start)
    return events


def fetch_ics(url: str) -> bytes:
    # Google/Canvas a veces entregan webcal://
    url = url.replace("webcal://", "https://", 1)
    r = _http.get(url)
    r.raise_for_status()
    return r.content
