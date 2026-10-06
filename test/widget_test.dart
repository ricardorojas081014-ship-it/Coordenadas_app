import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coordenadas_app/main.dart';

void main() {
  test('calcula la sección correcta de la última tesela con imagen', () {
    const requested = TileCoordinates(12345, 23459, 19);

    expect(
      EsriImageryImageProvider.ancestorCoordinates(requested, 17),
      const TileCoordinates(3086, 5864, 17),
    );
    expect(EsriImageryImageProvider.childColumn(requested, 17), 1);
    expect(EsriImageryImageProvider.childRow(requested, 17), 3);
  });

  test('muestra solo etiquetas de ciudades del servicio geográfico', () {
    final ciudades = CityMapLabel.parseResponse({
      'features': [
        {
          'attributes': {'FID': 462, 'CITY_NAME': 'Cucuta'},
          'geometry': {'x': -72.503, 'y': 7.891},
        },
      ],
    });

    expect(ciudades, hasLength(1));
    expect(ciudades.single.name, 'Cucuta');
    expect(ciudades.single.latitude, 7.891);
    expect(CityMapLabel.maxPopulationRank(5), isNull);
    expect(CityMapLabel.maxPopulationRank(7), 3);
    expect(CityMapLabel.maxPopulationRank(11), 7);
  });

  test('previsualiza una plantación exportada con sus puntos', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'coordenadas_plantacion',
          'version': 1,
          'project': {'nombre': 'Lote Norte'},
          'routes': [
            {
              'recorrido': {'nombre': 'Recorrido 1'},
              'puntos': [
                {
                  'latitud': 4.5,
                  'longitud': -74.1,
                  'altitud': 100,
                  'precision': 5,
                  'fecha': '2026-10-01T10:00:00.000',
                },
              ],
            },
          ],
        }),
      ),
    );

    final resumen = TransferenciaPlantacion.previsualizar(bytes);

    expect(resumen.nombre, 'Lote Norte');
    expect(resumen.cantidadRecorridos, 1);
    expect(resumen.cantidadPuntos, 1);
  });

  test('rechaza coordenadas inválidas en archivo de plantación', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'coordenadas_plantacion',
          'version': 1,
          'project': {'nombre': 'Lote Norte'},
          'routes': [
            {
              'recorrido': {'nombre': 'Recorrido 1'},
              'puntos': [
                {
                  'latitud': 100,
                  'longitud': -74.1,
                  'altitud': 100,
                  'precision': 5,
                  'fecha': '2026-10-01T10:00:00.000',
                },
              ],
            },
          ],
        }),
      ),
    );

    expect(
      () => TransferenciaPlantacion.previsualizar(bytes),
      throwsFormatException,
    );
  });

  testWidgets('muestra la pantalla principal de recorridos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CoordenadasApp());

    expect(find.text('Recorridos'), findsOneWidget);
  });
}
