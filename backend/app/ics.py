"""Lectura de calendarios ICS (Canvas, Google Calendar vía enlace secreto/público)."""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import httpx
import icalendar
import recurring_ical_events

_http = httpx.Client(timeout=18, follow_redirects=True)

# Caché en memoria de eventos ya parseados: evita re-ejecutar Calendar.from_ical y recurring_ical_events
# en cada petición cuando el contenido .ics y el rango de días no han cambiado.
_parsed_cache: dict[tuple[str, str, str, str, str], list[CalEvent]] = {}


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
    raw_bytes = data.encode("utf-8", errors="ignore") if isinstance(data, str) else data
    if not raw_bytes.strip():
        return []
    digest = hashlib.sha1(raw_bytes).hexdigest()
    cache_key = (
        digest,
        source,
        start.astimezone(tz).date().isoformat(),
        end.astimezone(tz).date().isoformat(),
        str(tz),
    )
    cached = _parsed_cache.get(cache_key)
    if cached is not None:
        return list(cached)

    cal = icalendar.Calendar.from_ical(raw_bytes)
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
    if len(_parsed_cache) > 64:
        _parsed_cache.clear()
    _parsed_cache[cache_key] = events
    return list(events)


def fetch_ics(url: str) -> bytes:
    # Google/Canvas a veces entregan webcal://
    url = url.replace("webcal://", "https://", 1)
    r = _http.get(url)
    r.raise_for_status()
    return r.content
