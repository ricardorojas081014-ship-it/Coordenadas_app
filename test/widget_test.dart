import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

  test(
    'usa el mosaico guardado al acercar sin pedir una tesela en línea',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'coordenadas_offline_tiles_',
      );
      ui.Image? image;
      ui.Picture? picture;
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 256, 256),
          ui.Paint()..color = const ui.Color(0xFF4A6B39),
        );
        picture = recorder.endRecording();
        image = await picture.toImage(256, 256);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final tile = File(
          '${directory.path}${Platform.pathSeparator}17'
          '${Platform.pathSeparator}12345${Platform.pathSeparator}23459.png',
        );
        await tile.parent.create(recursive: true);
        await tile.writeAsBytes(png!.buffer.asUint8List());

        final provider = EsriImageryImageProvider(
          coordinates: const TileCoordinates(24690, 46918, 18),
          directoryPath: directory.path,
          requestTile: (zoom, x, y) async {
            throw StateError('No debería solicitar mosaicos en línea.');
          },
        );
        final result = await provider.loadBestAvailableTile();

        expect(result, isNotEmpty);
      } finally {
        image?.dispose();
        picture?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

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

  test('interpreta coordenadas ingresadas en una sola línea', () {
    final point = MapCoordinateInput.parse('7.89, -72.50');

    expect(point.latitude, 7.89);
    expect(point.longitude, -72.5);
    expect(() => MapCoordinateInput.parse('91, -72.50'), throwsFormatException);
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
