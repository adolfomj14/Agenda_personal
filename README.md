# Agenda personal

Asistente para equilibrar **Universidad (Canvas) + Trabajo (Google Workspace)**: notas, tareas, calendario unificado, registro de tiempo y planificador automático.

```
backend/   API FastAPI + motor de planificación (Python)   ← listo y probado
app/       Cliente Flutter (Android, iOS, Windows)         ← código fuente base
render.yaml  Despliegue gratuito en Render
```

## Cómo enlazas tus calendarios (sin OAuth)
- **Canvas:** Calendario → "Fuente del calendario" (Calendar Feed) → copia el enlace `.ics`.
- **Google Calendar (trabajo):** Configuración del calendario → *Integrar calendario* → **Dirección secreta en formato iCal**.
  (Si el administrador de Workspace bloquea compartir, pídele habilitarlo o usa la API OAuth en una fase posterior.)

## Backend local
```powershell
cd backend
python -m venv .venv; .\.venv\Scripts\activate
pip install -r requirements.txt
pytest
$env:AGENDA_API_KEY="mi-clave"; uvicorn app.main:app --reload
# Documentación interactiva: http://127.0.0.1:8000/docs
```

Uso rápido (cabecera `X-API-Key`):
1. `POST /calendars` `{"name":"Canvas","context":"universidad","url":"https://...ics"}`
2. `POST /calendars/{id}/import-tasks` → convierte entregas de Canvas en tareas
3. `POST /tasks` para tareas propias; `POST /tasks/{id}/log` para registrar minutos
4. `GET /plan` → bloques sugeridos, estado por tarea (`ok | at_risk | late | done`), conflictos
5. `GET /stats` → tiempo por contexto, precisión de estimaciones, atrasadas

## Despliegue gratuito
1. Sube el repo a GitHub → Render → *New Blueprint* (usa `render.yaml`). Copia el `AGENDA_API_KEY` generado.
2. Render gratis "duerme" tras 15 min sin uso (primera petición tarda ~30 s) y su disco es efímero:
   para **persistir datos** migra `db.py` a **Turso (libSQL)** o **Neon (Postgres)**, ambos con plan gratuito.

## Cliente Flutter
Flutter no estaba instalado en este equipo. Pasos:
1. Instala Flutter (https://docs.flutter.dev/get-started/install/windows) y Visual Studio con "Desktop development with C++" (para Windows). iOS requiere una Mac para compilar.
2. `cd app; flutter create . --platforms=android,ios,windows --org com.agenda` (genera carpetas de plataforma sin tocar `lib/`).
3. `flutter pub get; flutter run -d windows` (o un emulador Android).
4. En **Ajustes** de la app pon la URL del servidor y tu API key.

## Siguientes fases
Notificaciones push (FCM), cronómetro en segundo plano, escritura de bloques a un calendario "Planner" en Google (OAuth), Gemini para extraer tareas, caché offline (Drift).
