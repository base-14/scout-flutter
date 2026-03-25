# Scout Flutter

Zero-config OpenTelemetry RUM (Real User Monitoring) for Flutter. Auto-captures taps, navigation, errors, and lifecycle events.

## Quick Start

### 1. Add dependency

```yaml
dependencies:
  scout_flutter:
    git:
      url: https://github.com/base-14/scout_flutter.git
```

### 2. Initialize in main()

```dart
import 'package:scout_flutter/scout_flutter.dart';

Future<void> main() async {
  await ScoutFlutter.initialize(
    config: ScoutFlutterConfig(
      serviceName: 'my-app',
      endpoint: 'https://your-otel-endpoint:4318',
    ),
  );
  runApp(const MyApp());
}
```

That's it. Taps, lifecycle events, and errors are captured automatically.

### 3. (Optional) Add navigation tracking

```dart
MaterialApp(
  navigatorObservers: [ScoutFlutter.navigatorObserver],
  // ...
)
```

## What's captured

| Signal | Auto | Details |
|--------|------|---------|
| Taps | Yes | Buttons, GestureDetectors, InkWells, Switches, Tabs |
| Lifecycle | Yes | Pause, resume, exit |
| Errors | Yes | FlutterError + uncaught exceptions |
| Navigation | Optional | Add `ScoutFlutter.navigatorObserver` to your app |
| Device info | Yes | Model, manufacturer, battery level |

## Custom Events

```dart
// Log a business event
ScoutFlutter.logEvent('purchase', attributes: {'item': 'widget'});

// Add breadcrumb for error context
ScoutFlutter.addBreadcrumb('checkout', 'added item to cart');

// Report error manually
ScoutFlutter.reportError(error, stackTrace);

// Set user identity
ScoutFlutter.setUser(id: 'user-123', email: 'user@example.com');
```

## Annotate Widgets

For custom tap labels on widgets the SDK can't auto-label:

```dart
RumUserActionAnnotation(
  description: 'Add to cart',
  child: MyCustomWidget(),
)
```

## Configuration

```dart
ScoutFlutterConfig(
  serviceName: 'my-app',           // required
  endpoint: 'https://...:4318',    // required - OTel collector endpoint
  serviceVersion: '1.0.0',
  environment: 'production',
  secure: true,                    // use HTTPS
  enableAutoTapTracking: true,
  enableErrorTracking: true,
  enableLifecycleTracking: true,
  resourceAttributes: {'key': 'value'},
)
```

## License

MIT
