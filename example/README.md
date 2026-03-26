# Scout Flutter Example

Demonstrates the `scout_flutter` package with auto-captured telemetry.

## Running

```bash
# With default endpoint (localhost:4318)
flutter run

# With custom OTLP collector endpoint
flutter run --dart-define=OTEL_ENDPOINT=http://your-collector:4318
```

## What to try

- **Tap buttons** — `user_interaction` spans are emitted automatically
- **Navigate between screens** — `screen_view`, `screen_load`, `view_session` spans
- **Trigger test error** — Reports error with breadcrumb trail
- **Log custom event** — Emits a custom span
- **Set user identity** — Attaches user ID to all subsequent spans
- **Background/foreground the app** — Lifecycle breadcrumbs + crash marker tracking
- **Kill the app from task switcher** — Next launch emits `app_crash` span with breadcrumbs

## Android device setup

If running the OTLP collector on your host machine:

```bash
adb reverse tcp:4318 tcp:4318
```

Re-run this after each app crash/restart since the port forwarding is per-process.
