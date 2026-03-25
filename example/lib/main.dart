import 'package:scout_flutter/scout_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  await ScoutFlutter.initialize(
    config: ScoutFlutterConfig(
      serviceName: 'scout-flutter-example',
      serviceVersion: '1.0.0',
      endpoint: const String.fromEnvironment(
        'OTEL_ENDPOINT',
        defaultValue: 'http://localhost:4318',
      ),
      secure: false,
      environment: 'development',
    ),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scout Flutter Example',
      navigatorObservers: [ScoutFlutter.navigatorObserver],
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scout Flutter Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DetailScreen()),
              );
            },
            child: const Text('Go to Detail'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            child: const Text('Settings'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              ScoutFlutter.logEvent('custom_event', attributes: {
                'source': 'home_screen',
              });
            },
            child: const Text('Log Custom Event'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              ScoutFlutter.reportError(
                Exception('Test error from UI'),
                StackTrace.current,
              );
            },
            child: const Text('Trigger Test Error'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              ScoutFlutter.setUser(id: 'user-42', email: 'test@example.com');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('User identity set')),
              );
            },
            child: const Text('Set User Identity'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Icon button: '),
              IconButton(
                icon: const Icon(Icons.star, semanticLabel: 'Favorite'),
                onPressed: () {},
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Notifications'),
            value: true,
            onChanged: (_) {},
          ),
        ],
      ),
    );
  }
}

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detail')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Detail screen — auto-tracked!'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Account'),
            leading: const Icon(Icons.account_circle),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Privacy'),
            leading: const Icon(Icons.lock),
            onTap: () {},
          ),
          SwitchListTile(
            title: const Text('Dark Mode'),
            value: false,
            onChanged: (_) {},
          ),
        ],
      ),
    );
  }
}
