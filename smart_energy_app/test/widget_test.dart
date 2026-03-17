import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_energy_app/main.dart';

void main() {
  testWidgets('Dashboard shows app title', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartEnergyApp());
    // Let async initState (_autoConnect) settle without a real broker.
    await tester.pump();

    expect(find.text('Smart Energy Monitor'), findsOneWidget);
  });

  testWidgets('Dashboard shows settings button', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartEnergyApp());
    await tester.pump();

    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  testWidgets('Not-connected placeholder and configure button are shown',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartEnergyApp());
    await tester.pump();

    // When no broker is configured the "configure" button must be visible.
    expect(find.text('Configurer le broker'), findsOneWidget);
  });

  testWidgets('Settings screen opens when configure button is tapped',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartEnergyApp());
    await tester.pump();

    await tester.tap(find.text('Configurer le broker'));
    await tester.pumpAndSettle();

    expect(find.text('Paramètres MQTT'), findsOneWidget);
  });
}
