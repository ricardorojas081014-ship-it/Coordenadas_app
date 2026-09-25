import 'package:flutter_test/flutter_test.dart';

import 'package:coordenadas_app/main.dart';

void main() {
  testWidgets('muestra la pantalla principal de recorridos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CoordenadasApp());

    expect(find.text('Recorridos'), findsOneWidget);
  });
}
