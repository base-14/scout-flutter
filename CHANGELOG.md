## 0.1.0

- Initial release
- Auto tap detection via global pointer route (zero widget changes required)
- Auto lifecycle tracking (pause, resume, exit)
- Auto error tracking (FlutterError + uncaught errors)
- Optional navigation tracking via `ScoutFlutter.navigatorObserver`
- Device info and battery level collection
- Breadcrumb manager for error context
- Custom event logging via `ScoutFlutter.logEvent()`
- User identity tracking via `ScoutFlutter.setUser()`
- `RumUserActionAnnotation` widget for custom action labels
- OpenTelemetry export via `flutterrific_opentelemetry`
