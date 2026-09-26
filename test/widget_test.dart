// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sinema/main.dart';
import 'package:sinema/settings_controller.dart';

void main() {
  testWidgets('shows Jellyfin sign-in form', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    await tester.pumpWidget(SinemaApp(settings: settings));

    expect(find.text('Welcome to Sinema.'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Sign In'), findsOneWidget);
  });
}
