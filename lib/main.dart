import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  runApp(const CoordenadasApp());
}

class CoordenadasApp extends StatelessWidget {
  const CoordenadasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Coordenadas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const InicioRecorridosPage(),
    );
  }
}

class OfflineTileStore {
  static const int zoom = 17;
  static const String url =
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Imagery/MapServer/tile';

  static Future<Directory> _root() async {
    final base = await getApplicationDocumentsDirectory();
    final directory = Directory(path.join(base.path, 'tiles_satelitales'));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<String> tilePath(int x, int y) async {
    final root = await _root();
    final directory = Directory(path.join(root.path, '$zoom', '$x'));
    await directory.create(recursive: true);
    return path.join(directory.path, '$y.png');
  }

  static String _url(int x, int y) => '$url/$zoom/$y/$x';

  static Future<int> download({
    required LatLng center,
    required double areaKm2,
    void Function(int completed, int total)? onProgress,
  }) async {
    final sideKm = math.sqrt(areaKm2);
    final latitudeDelta = sideKm / 111.32;
    final longitudeDelta =
        sideKm / (111.32 * math.cos(center.latitude * math.pi / 180));
    final min = _tile(
      center.latitude + latitudeDelta / 2,
      center.longitude - longitudeDelta / 2,
    );
    final max = _tile(
      center.latitude - latitudeDelta / 2,
      center.longitude + longitudeDelta / 2,
    );
    final minX = math.min(min[0], max[0]);
    final maxX = math.max(min[0], max[0]);
    final minY = math.min(min[1], max[1]);
    final maxY = math.max(min[1], max[1]);
    final total = (maxX - minX + 1) * (maxY - minY + 1);
    if (total > 2500) {
      throw Exception('Reduce el área: supera 2500 mosaicos.');
    }

    var completed = 0;
    var saved = 0;
    for (var x = minX; x <= maxX; x++) {
      for (var y = minY; y <= maxY; y++) {
        final target = File(await tilePath(x, y));
        if (!await target.exists()) {
          final response = await http.get(Uri.parse(_url(x, y)));
          if (response.statusCode == 200 &&
              response.bodyBytes.isNotEmpty &&
              EsriImageryImageProvider.hasImagery(response.bodyBytes)) {
            await target.writeAsBytes(response.bodyBytes, flush: true);
            saved++;
          }
        }
        completed++;
        onProgress?.call(completed, total);
      }
    }
    return saved;
  }

  static List<int> _tile(double latitude, double longitude) {
    final lat = latitude.clamp(-85.0511, 85.0511);
    final n = math.pow(2, zoom);
    final x = ((longitude + 180) / 360 * n).floor();
    final y =
        ((1 -
                    math.log(
                          math.tan(lat * math.pi / 180) +
                              1 / math.cos(lat * math.pi / 180),
                        ) /
                        math.pi) /
                2 *
                n)
            .floor();
    return [x, y];
  }
}

class MapCoordinateInput {
  static LatLng parse(String input) {
    final values = input.trim().split(RegExp(r'[,;\s]+'));
    if (values.length != 2) {
      throw const FormatException(
        'Ingresa latitud y longitud en una sola línea, por ejemplo: 7.89, -72.50.',
      );
    }

    final latitude = double.tryParse(values[0]);
    final longitude = double.tryParse(values[1]);
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException(
        'Ingresa coordenadas válidas. Latitud: -90 a 90; longitud: -180 a 180.',
      );
    }

    return LatLng(latitude, longitude);
  }
}

class CityMapLabel {
  const CityMapLabel({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  static const String _queryUrl =
      'https://services.arcgis.com/P3ePLMYs2RVChkJx/arcgis/rest/services/'
      'World_Cities/FeatureServer/0/query';

  final int id;
  final String name;
  final double latitude;
  final double longitude;

  static int? maxPopulationRank(double zoom) {
    if (zoom < 6) return null;
    if (zoom < 8) return 3;
    if (zoom < 10) return 5;
    if (zoom < 12) return 7;
    return 10;
  }

  static Future<List<CityMapLabel>> load({
    required http.Client client,
    required LatLngBounds bounds,
    required double zoom,
  }) async {
    final maxRank = maxPopulationRank(zoom);
    if (maxRank == null) return const [];
    final uri = Uri.parse(_queryUrl).replace(
      queryParameters: {
        'where': 'POP > 0 AND POP_RANK <= $maxRank',
        'geometry': [
          bounds.west.toStringAsFixed(5),
          bounds.south.toStringAsFixed(5),
          bounds.east.toStringAsFixed(5),
          bounds.north.toStringAsFixed(5),
        ].join(','),
        'geometryType': 'esriGeometryEnvelope',
        'inSR': '4326',
        'outFields': 'FID,CITY_NAME',
        'returnGeometry': 'true',
        'outSR': '4326',
        'resultRecordCount': '500',
        'f': 'json',
      },
    );
    final response = await client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'El servicio de nombres de ciudades respondió '
        'HTTP ${response.statusCode}.',
        uri: uri,
      );
    }
    final decoded = jsonDecode(response.body);
    return parseResponse(decoded);
  }

  static List<CityMapLabel> parseResponse(Object? decoded) {
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'El servicio de nombres de ciudades devolvió una respuesta inválida.',
      );
    }
    final error = decoded['error'];
    if (error != null) {
      throw FormatException(
        'No se pudieron cargar los nombres de ciudades: '
        '${error is Map ? error['message'] : error}',
      );
    }
    final features = decoded['features'];
    if (features is! List) {
      throw const FormatException(
        'La respuesta del servicio de ciudades no contiene lugares.',
      );
    }
    final labels = <CityMapLabel>[];
    for (final feature in features) {
      if (feature is! Map<String, dynamic> ||
          feature['attributes'] is! Map<String, dynamic> ||
          feature['geometry'] is! Map<String, dynamic>) {
        continue;
      }
      labels.add(
        _parse(
          feature['attributes'] as Map<String, dynamic>,
          feature['geometry'] as Map<String, dynamic>,
        ),
      );
    }
    return labels;
  }

  static CityMapLabel _parse(
    Map<String, dynamic> attributes,
    Map<String, dynamic> geometry,
  ) {
    final id = attributes['FID'];
    final name = attributes['CITY_NAME'];
    final latitude = geometry['y'];
    final longitude = geometry['x'];
    if (id is! num ||
        name is! String ||
        name.trim().isEmpty ||
        latitude is! num ||
        longitude is! num ||
        !latitude.toDouble().isFinite ||
        !longitude.toDouble().isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException(
        'El servicio de ciudades devolvió un lugar inválido.',
      );
    }
    return CityMapLabel(
      id: id.toInt(),
      name: name.trim(),
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }
}

class EsriImageryTileProvider extends TileProvider {
  final http.Client _client = http.Client();
  final Map<String, Future<Uint8List?>> _tileCache = {};

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return EsriImageryImageProvider(
      coordinates: coordinates,
      directoryPath: _directoryPath,
      requestTile: _requestTile,
    );
  }

  Future<Uint8List?> _requestTile(int zoom, int x, int y) async {
    final key = '$zoom/$y/$x';
    final request = _tileCache.putIfAbsent(key, () async {
      final response = await _client.get(
        Uri.parse('${OfflineTileStore.url}/$zoom/$y/$x'),
        headers: headers,
      );
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Esri respondió HTTP ${response.statusCode} al cargar una tesela.',
          uri: response.request?.url,
        );
      }
      if (response.bodyBytes.isEmpty) {
        throw FormatException('Esri devolvió una tesela vacía en zoom $zoom.');
      }
      return response.bodyBytes;
    });

    try {
      final bytes = await request;
      if (_tileCache.length > 256) {
        _tileCache.remove(_tileCache.keys.first);
      }
      return bytes;
    } catch (error, stackTrace) {
      _tileCache.remove(key);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  void dispose() {
    _tileCache.clear();
    _client.close();
    super.dispose();
  }

  static String _directoryPath = '';

  static Future<void> prepare() async {
    final directory = await OfflineTileStore._root();
    _directoryPath = directory.path;
  }

  static Future<String> ensurePrepared() async {
    if (_directoryPath.isEmpty) await prepare();
    return _directoryPath;
  }
}

class EsriImageryImageProvider extends ImageProvider<EsriImageryImageProvider> {
  const EsriImageryImageProvider({
    required this.coordinates,
    required this.directoryPath,
    required this.requestTile,
  });

  // ArcGIS returns this same placeholder image with HTTP 200 for empty tiles.
  static const String _noDataTileSha256 =
      '9eafd300d61393184a4abc1d458564cfd1cd9b6f9c4e9c74687045c0a0e5b858';

  static bool hasImagery(Uint8List bytes) =>
      sha256.convert(bytes).toString() != _noDataTileSha256;

  final TileCoordinates coordinates;
  final String directoryPath;
  final Future<Uint8List?> Function(int zoom, int x, int y) requestTile;

  @visibleForTesting
  static TileCoordinates ancestorCoordinates(
    TileCoordinates coordinates,
    int zoom,
  ) {
    if (zoom < 0 || zoom > coordinates.z) {
      throw RangeError.range(zoom, 0, coordinates.z, 'zoom');
    }
    final factor = 1 << (coordinates.z - zoom);
    return TileCoordinates(
      coordinates.x ~/ factor,
      coordinates.y ~/ factor,
      zoom,
    );
  }

  @visibleForTesting
  static int childColumn(TileCoordinates coordinates, int ancestorZoom) =>
      coordinates.x % (1 << (coordinates.z - ancestorZoom));

  @visibleForTesting
  static int childRow(TileCoordinates coordinates, int ancestorZoom) =>
      coordinates.y % (1 << (coordinates.z - ancestorZoom));

  @override
  Future<EsriImageryImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture<EsriImageryImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    EsriImageryImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _loadImage(key, decode),
    scale: 1,
    debugLabel:
        'Esri imagery tile ${coordinates.z}/${coordinates.y}/${coordinates.x}',
  );

  Future<ui.Codec> _loadImage(
    EsriImageryImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.loadBestAvailableTile();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @visibleForTesting
  Future<Uint8List> loadBestAvailableTile() async {
    var offlineDirectoryPath = directoryPath;
    if (coordinates.z >= OfflineTileStore.zoom &&
        offlineDirectoryPath.isEmpty) {
      offlineDirectoryPath = await EsriImageryTileProvider.ensurePrepared();
    }
    if (coordinates.z >= OfflineTileStore.zoom) {
      final offlineCoordinates = ancestorCoordinates(
        coordinates,
        OfflineTileStore.zoom,
      );
      final offlineTile = File(
        path.join(
          offlineDirectoryPath,
          '${OfflineTileStore.zoom}',
          '${offlineCoordinates.x}',
          '${offlineCoordinates.y}.png',
        ),
      );
      if (await offlineTile.exists()) {
        final bytes = await offlineTile.readAsBytes();
        if (hasImagery(bytes)) {
          if (coordinates.z == OfflineTileStore.zoom) return bytes;
          return _cropAncestorTile(
            bytes: bytes,
            sourceZoom: OfflineTileStore.zoom,
          );
        }
      }
    }

    for (var zoom = coordinates.z; zoom >= 0; zoom--) {
      final sourceTile = ancestorCoordinates(coordinates, zoom);
      final x = sourceTile.x;
      final y = sourceTile.y;
      final Uint8List? bytes;

      if (zoom == OfflineTileStore.zoom && offlineDirectoryPath.isNotEmpty) {
        final cachedTile = File(
          path.join(offlineDirectoryPath, '$zoom', '$x', '$y.png'),
        );
        if (await cachedTile.exists()) {
          bytes = await cachedTile.readAsBytes();
        } else {
          bytes = await requestTile(zoom, x, y);
        }
      } else {
        bytes = await requestTile(zoom, x, y);
      }

      if (bytes == null) continue;
      if (!hasImagery(bytes)) continue;
      if (zoom == coordinates.z) return bytes;

      return _cropAncestorTile(bytes: bytes, sourceZoom: zoom);
    }

    throw StateError(
      'Esri no dispone de imágenes para la tesela '
      '${coordinates.z}/${coordinates.y}/${coordinates.x}.',
    );
  }

  Future<Uint8List> _cropAncestorTile({
    required Uint8List bytes,
    required int sourceZoom,
  }) async {
    final shift = coordinates.z - sourceZoom;
    final factor = 1 << shift;
    final column = childColumn(coordinates, sourceZoom);
    final row = childRow(coordinates, sourceZoom);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final tileSize = image.width / factor;
    final sourceRect = ui.Rect.fromLTWH(
      tileSize * column,
      tileSize * row,
      tileSize,
      tileSize,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      sourceRect,
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final cropped = await recorder.endRecording().toImage(256, 256);
    final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    cropped.dispose();
    codec.dispose();
    if (png == null) {
      throw StateError('No se pudo ampliar la imagen satelital de Esri.');
    }
    return png.buffer.asUint8List();
  }

  @override
  bool operator ==(Object other) =>
      other is EsriImageryImageProvider &&
      other.coordinates == coordinates &&
      other.directoryPath == directoryPath;

  @override
  int get hashCode => Object.hash(coordinates, directoryPath);
}

class InicioRecorridosPage extends StatefulWidget {
  const InicioRecorridosPage({super.key});

  @override
  State<InicioRecorridosPage> createState() => _InicioRecorridosPageState();
}

class _InicioRecorridosPageState extends State<InicioRecorridosPage> {
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _suscripcionUbicacion;
  StreamSubscription<CompassEvent>? _suscripcionRumbo;
  List<Proyecto> _plantaciones = [];
  Position? _posicion;
  LatLng? _coordenadaSeleccionada;
  double? _rumbo;
  double _zoomMapa = 19;
  double _latitudMapa = 4.7110;
  bool _cargando = true;
  bool _obteniendoUbicacion = false;
  bool _descargandoZonaActiva = false;
  bool _disposed = false;
  String? _error;
  Timer? _temporizadorCamara;
  Timer? _temporizadorCiudades;
  final http.Client _clienteCiudades = http.Client();
  List<CityMapLabel> _ciudades = [];
  String? _consultaCiudadesActual;
  int _solicitudCiudades = 0;
  bool _avisoCiudadesMostrado = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepararMosaicosOffline());
    _cargarPlantaciones();
    _obtenerUbicacion();
  }

  @override
  void dispose() {
    _disposed = true;
    _temporizadorCamara?.cancel();
    _temporizadorCiudades?.cancel();
    _clienteCiudades.close();
    final subscription = _suscripcionUbicacion;
    _suscripcionUbicacion = null;
    unawaited(subscription?.cancel());
    unawaited(_suscripcionRumbo?.cancel());
    _suscripcionRumbo = null;
    super.dispose();
  }

  Future<void> _prepararMosaicosOffline() async {
    try {
      await EsriImageryTileProvider.prepare();
      if (mounted && !_disposed) setState(() {});
    } catch (error) {
      if (mounted && !_disposed) {
        _mostrarAviso('No se pudo preparar la caché del mapa: $error');
      }
    }
  }

  Future<void> _cargarPlantaciones() async {
    try {
      final plantaciones = await PuntosDatabase.obtenerProyectos();
      if (!mounted) return;
      setState(() {
        _plantaciones = plantaciones;
        _cargando = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudieron cargar las plantaciones: $error';
      });
    }
  }

  Future<void> _obtenerUbicacion() async {
    if (_obteniendoUbicacion) return;
    setState(() {
      _obteniendoUbicacion = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Activa el servicio de ubicación.');
      }
      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
      }
      if (permiso == LocationPermission.denied ||
          permiso == LocationPermission.deniedForever) {
        throw Exception('Se necesita permiso de ubicación.');
      }
      final posicion = await Geolocator.getCurrentPosition();
      if (!mounted || _disposed) return;
      setState(() => _posicion = posicion);
      _moverMapa(LatLng(posicion.latitude, posicion.longitude), 17);
      _suscribirseUbicacion();
      _suscribirseBrujula();
    } catch (error) {
      if (mounted && !_disposed) setState(() => _error = error.toString());
    } finally {
      if (mounted && !_disposed) setState(() => _obteniendoUbicacion = false);
    }
  }

  void _suscribirseUbicacion() {
    if (_suscripcionUbicacion != null || _disposed) return;
    _suscripcionUbicacion =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 2,
          ),
        ).listen((posicion) {
          if (!mounted || _disposed) return;
          setState(() => _posicion = posicion);
        });
  }

  void _suscribirseBrujula() {
    if (_suscripcionRumbo != null || _disposed) return;
    final eventos = FlutterCompass.events;
    if (eventos == null) return;
    _suscripcionRumbo = eventos.listen(_actualizarRumbo);
  }

  void _actualizarRumbo(CompassEvent evento) {
    final rumbo = evento.heading;
    if (!mounted || _disposed || rumbo == null) return;
    setState(() => _rumbo = rumbo);
  }

  void _actualizarVistaMapa(MapCamera camera, bool hasGesture) {
    if (!mounted || _disposed) return;
    _programarActualizacionCamara(camera.zoom, camera.center.latitude);
    _programarCargaCiudades(camera);
  }

  void _programarCargaCiudades(MapCamera camera) {
    _temporizadorCiudades?.cancel();
    _temporizadorCiudades = Timer(const Duration(milliseconds: 450), () {
      unawaited(_cargarCiudades(camera));
    });
  }

  Future<void> _cargarCiudades(MapCamera camera) async {
    if (!mounted || _disposed) return;
    if (CityMapLabel.maxPopulationRank(camera.zoom) == null) {
      _consultaCiudadesActual = null;
      _solicitudCiudades++;
      if (_ciudades.isNotEmpty) setState(() => _ciudades = []);
      return;
    }
    final bounds = camera.visibleBounds;
    final consulta = [
      bounds.west.toStringAsFixed(3),
      bounds.south.toStringAsFixed(3),
      bounds.east.toStringAsFixed(3),
      bounds.north.toStringAsFixed(3),
      CityMapLabel.maxPopulationRank(camera.zoom),
    ].join(',');
    if (_consultaCiudadesActual == consulta) return;
    _consultaCiudadesActual = consulta;
    final solicitud = ++_solicitudCiudades;
    try {
      final ciudades = await CityMapLabel.load(
        client: _clienteCiudades,
        bounds: bounds,
        zoom: camera.zoom,
      );
      if (!mounted || _disposed || solicitud != _solicitudCiudades) return;
      setState(() => _ciudades = ciudades);
    } catch (error) {
      if (!mounted || _disposed || solicitud != _solicitudCiudades) return;
      _consultaCiudadesActual = null;
      if (!_avisoCiudadesMostrado) {
        _avisoCiudadesMostrado = true;
        _mostrarAviso('No se pudieron cargar los nombres de ciudades: $error');
      }
    }
  }

  Marker _marcadorCiudad(CityMapLabel ciudad) => Marker(
    point: LatLng(ciudad.latitude, ciudad.longitude),
    width: 150,
    height: 28,
    alignment: Alignment.center,
    child: IgnorePointer(
      child: Text(
        ciudad.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(color: Colors.black, blurRadius: 3),
            Shadow(color: Colors.black, blurRadius: 5),
          ],
        ),
      ),
    ),
  );

  void _programarActualizacionCamara(double zoom, double latitud) {
    _temporizadorCamara?.cancel();
    _temporizadorCamara = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _disposed) return;
      setState(() {
        _zoomMapa = zoom;
        _latitudMapa = latitud;
      });
    });
  }

  void _moverMapa(LatLng punto, double zoom) {
    _mapController.move(punto, zoom);
  }

  void _seleccionarCoordenada(TapPosition _, LatLng punto) {
    _seleccionarPunto(punto);
  }

  void _seleccionarPunto(LatLng punto) {
    if (!mounted || _disposed) return;
    setState(() => _coordenadaSeleccionada = punto);
  }

  Future<LatLng?> _ingresarCoordenadasDescarga() async {
    final coordenadasController = TextEditingController();
    try {
      return await showDialog<LatLng>(
        context: context,
        builder: (dialogContext) {
          var error = '';
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              title: const Text('Coordenadas del centro'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    autofocus: true,
                    controller: coordenadasController,
                    keyboardType: TextInputType.text,
                    decoration: const InputDecoration(
                      labelText: 'Latitud, longitud',
                      hintText: 'Ej. 7.89, -72.50',
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    try {
                      Navigator.pop(
                        dialogContext,
                        MapCoordinateInput.parse(coordenadasController.text),
                      );
                    } on FormatException catch (exception) {
                      setDialogState(() => error = exception.message);
                    }
                  },
                  child: const Text('Usar coordenadas'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      coordenadasController.dispose();
    }
  }

  Future<void> _descargarZona() async {
    if (!mounted || _descargandoZonaActiva) return;
    final gpsPosition = _posicion;
    final centro = await showDialog<LatLng>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Elegir centro de descarga'),
        children: [
          if (_coordenadaSeleccionada != null)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(dialogContext, _coordenadaSeleccionada),
              child: const Text('Usar el punto marcado en el mapa'),
            ),
          if (gpsPosition != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialogContext,
                LatLng(gpsPosition.latitude, gpsPosition.longitude),
              ),
              child: const Text('Usar mi ubicación actual'),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final point = await _ingresarCoordenadasDescarga();
              if (point != null && dialogContext.mounted) {
                Navigator.pop(dialogContext, point);
              }
            },
            child: const Text('Ingresar coordenadas'),
          ),
        ],
      ),
    );
    if (!mounted || centro == null) return;

    final area = await showDialog<double>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Tamaño de la zona'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Se descargará un cuadrado alrededor del centro.'),
          ),
          for (final km2 in [1.0, 4.0, 9.0, 16.0])
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(km2),
              child: Text('${km2.toStringAsFixed(0)} km2'),
            ),
        ],
      ),
    );
    if (!mounted || area == null) return;

    _descargandoZonaActiva = true;
    var progreso = 0;
    var total = 1;
    void Function(void Function())? actualizarDialogo;
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          actualizarDialogo = setDialogState;
          return AlertDialog(
            title: const Text('Descargando mapas'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: total <= 1 ? null : progreso / total,
                ),
                const SizedBox(height: 12),
                Text('$progreso de $total mosaicos'),
              ],
            ),
          );
        },
      ),
    );
    try {
      final saved = await OfflineTileStore.download(
        center: centro,
        areaKm2: area,
        onProgress: (completed, count) {
          progreso = completed;
          total = count;
          actualizarDialogo?.call(() {});
        },
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _mostrarAviso('$saved mosaicos guardados para uso offline.');
      }
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _mostrarAviso('No se pudo descargar la zona: $error');
      }
    } finally {
      _descargandoZonaActiva = false;
    }
  }

  Future<void> _buscarCoordenadas() async {
    var coordenadasTexto = '';
    final punto = await showDialog<LatLng>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        var error = '';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Ir a coordenadas'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  autofocus: true,
                  keyboardType: TextInputType.text,
                  onChanged: (value) => coordenadasTexto = value,
                  decoration: const InputDecoration(
                    labelText: 'Latitud, longitud',
                    hintText: 'Ej. 4.7110, -74.0721',
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext, rootNavigator: true).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    Navigator.of(
                      dialogContext,
                      rootNavigator: true,
                    ).pop(MapCoordinateInput.parse(coordenadasTexto));
                  } on FormatException catch (exception) {
                    setDialogState(() => error = exception.message);
                  }
                },
                child: const Text('Ubicar'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || _disposed || punto == null) return;
    setState(() => _coordenadaSeleccionada = punto);
    _moverMapa(punto, 19);
  }

  void _mostrarAviso(String mensaje) {
    if (!mounted || _disposed) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(mensaje)));
  }

  @override
  Widget build(BuildContext context) {
    final posicion = _posicion;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recorridos'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Ir a coordenadas',
            onPressed: _buscarCoordenadas,
            icon: const Icon(Icons.travel_explore),
          ),
          IconButton(
            tooltip: 'Descargar zona para uso offline',
            onPressed: _descargandoZonaActiva ? null : _descargarZona,
            icon: const Icon(Icons.download_for_offline),
          ),
          IconButton(
            tooltip: 'Plantaciones',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ProyectosPage()),
              );
              if (mounted) _cargarPlantaciones();
            },
            icon: const Icon(Icons.agriculture),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: posicion == null
                          ? const LatLng(4.7110, -74.0721)
                          : LatLng(posicion.latitude, posicion.longitude),
                      initialZoom: posicion == null ? 6 : 17,
                      maxZoom: 24,
                      backgroundColor: const Color(0xFF53624F),
                      onMapReady: () =>
                          _programarCargaCiudades(_mapController.camera),
                      onPositionChanged: _actualizarVistaMapa,
                      onTap: _seleccionarCoordenada,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: '${OfflineTileStore.url}/{z}/{y}/{x}',
                        userAgentPackageName: 'com.example.coordenadas_app',
                        maxNativeZoom: 23,
                        tileProvider: EsriImageryTileProvider(),
                      ),
                      MarkerLayer(
                        markers: _ciudades.map(_marcadorCiudad).toList(),
                      ),
                      MarkerLayer(
                        markers: _plantaciones
                            .where(
                              (plantacion) =>
                                  plantacion.latitud != null &&
                                  plantacion.longitud != null,
                            )
                            .map((plantacion) {
                              final punto = LatLng(
                                plantacion.latitud!,
                                plantacion.longitud!,
                              );
                              return Marker(
                                point: punto,
                                width: 220,
                                height: 38,
                                alignment: Alignment.center,
                                child: GestureDetector(
                                  onTap: () => _moverMapa(punto, 18),
                                  child: Tooltip(
                                    message: 'Plantación: ${plantacion.nombre}',
                                    child: Stack(
                                      children: [
                                        Positioned(
                                          left: 101,
                                          top: 10,
                                          child: Container(
                                            width: 18,
                                            height: 18,
                                            decoration: BoxDecoration(
                                              color: Colors.green.shade700,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 3,
                                              ),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black38,
                                                  blurRadius: 4,
                                                  offset: Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: 125,
                                          right: 0,
                                          top: 6,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.94,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black26,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            child: Text(
                                              plantacion.nombre,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.black87,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            })
                            .toList(),
                      ),
                      if (posicion != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: LatLng(
                                posicion.latitude,
                                posicion.longitude,
                              ),
                              width: 48,
                              height: 48,
                              child: _MarcadorUbicacion(
                                rumbo: _rumbo ?? posicion.heading,
                                precision: posicion.accuracy,
                              ),
                            ),
                          ],
                        ),
                      if (_coordenadaSeleccionada != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: _coordenadaSeleccionada!,
                              width: 42,
                              height: 42,
                              child: const Icon(
                                Icons.add_location_alt,
                                color: Colors.red,
                                size: 36,
                              ),
                            ),
                          ],
                        ),
                      RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution(
                            'Source: Esri, Vantor, Earthstar Geographics, '
                            'and the GIS User Community. City names: Esri '
                            'World Cities data.',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _IndicadorVistaMapa(zoom: _zoomMapa, latitud: _latitudMapa),
                _CoordenadasMapa(
                  punto:
                      _coordenadaSeleccionada ??
                      (posicion == null
                          ? null
                          : LatLng(posicion.latitude, posicion.longitude)),
                  etiqueta: _coordenadaSeleccionada == null
                      ? 'Ubicacion actual'
                      : 'Punto seleccionado',
                ),
                _IndicadorBrujula(rumbo: _rumbo ?? posicion?.heading),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _obteniendoUbicacion
                            ? null
                            : _obtenerUbicacion,
                        icon: const Icon(Icons.my_location),
                        label: Text(
                          _obteniendoUbicacion
                              ? 'Obteniendo ubicación...'
                              : 'Centrar en mi ubicación',
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ProyectosPage(),
                            ),
                          );
                          if (mounted) _cargarPlantaciones();
                        },
                        icon: const Icon(Icons.agriculture),
                        label: Text(
                          _plantaciones.isEmpty
                              ? 'Crear una plantación'
                              : 'Abrir plantaciones e iniciar recorrido',
                        ),
                      ),
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _CargandoOperacion extends StatelessWidget {
  const _CargandoOperacion({required this.mensaje});

  final String mensaje;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black38,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(mensaje),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IndicadorVistaMapa extends StatelessWidget {
  const _IndicadorVistaMapa({required this.zoom, required this.latitud});

  final double zoom;
  final double latitud;

  @override
  Widget build(BuildContext context) {
    final metrosPorPixel =
        156543.03392 * math.cos(latitud * math.pi / 180) / math.pow(2, zoom);
    final altoMapa = MediaQuery.sizeOf(context).height * 0.42;
    final piesVista = (metrosPorPixel * altoMapa / 2 * 3.28084)
        .clamp(1, double.infinity)
        .round();
    final metrosVista = (piesVista / 3.28084).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Card(
          margin: const EdgeInsets.only(top: 4, bottom: 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              'Zoom ${zoom.toStringAsFixed(1)} · '
              'Vista aprox.: $metrosVista m / $piesVista pies',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
    );
  }
}

class _CoordenadasMapa extends StatelessWidget {
  const _CoordenadasMapa({required this.punto, required this.etiqueta});

  final LatLng? punto;
  final String etiqueta;

  @override
  Widget build(BuildContext context) {
    if (punto == null) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Card(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            '$etiqueta\n'
            'Lat: ${punto!.latitude.toStringAsFixed(6)}\n'
            'Lon: ${punto!.longitude.toStringAsFixed(6)}',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

class _IndicadorBrujula extends StatelessWidget {
  const _IndicadorBrujula({required this.rumbo});

  final double? rumbo;

  String _direccion(double valor) {
    const nombres = [
      'Norte',
      'Noreste',
      'Este',
      'Sureste',
      'Sur',
      'Suroeste',
      'Oeste',
      'Noroeste',
    ];
    final indice = ((valor + 22.5) / 45).floor() % nombres.length;
    return nombres[indice];
  }

  @override
  Widget build(BuildContext context) {
    final valor = rumbo != null && rumbo!.isFinite && rumbo! >= 0
        ? rumbo!
        : null;
    final direccion = valor == null ? 'Sin señal' : _direccion(valor);
    final angulo = valor == null ? 0.0 : valor * math.pi / 180;

    return Align(
      alignment: Alignment.centerLeft,
      child: Card(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: angulo,
                child: const Icon(
                  Icons.navigation,
                  color: Colors.red,
                  size: 25,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$direccion${valor == null ? '' : ' · ${valor.toStringAsFixed(0)}°'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarcadorUbicacion extends StatelessWidget {
  const _MarcadorUbicacion({required this.rumbo, required this.precision});

  final double rumbo;
  final double precision;

  @override
  Widget build(BuildContext context) {
    final angulo = rumbo.isFinite && rumbo >= 0 ? rumbo * math.pi / 180 : 0.0;
    final radio = precision.isFinite ? precision.clamp(8.0, 45.0) : 12.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: radio * 2,
          height: radio * 2,
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
        ),
        Transform.rotate(
          angle: angulo,
          child: CustomPaint(
            size: const Size(44, 44),
            painter: _FlechaRumboPainter(),
          ),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
          ),
        ),
      ],
    );
  }
}

class _FlechaRumboPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centro = Offset(size.width / 2, size.height / 2);
    final ruta = ui.Path()
      ..moveTo(centro.dx, 2)
      ..lineTo(centro.dx - 9, centro.dy + 11)
      ..lineTo(centro.dx, centro.dy + 7)
      ..lineTo(centro.dx + 9, centro.dy + 11)
      ..close();
    canvas.drawPath(ruta, Paint()..color = Colors.blue.withValues(alpha: 0.85));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class Proyecto {
  const Proyecto({
    required this.id,
    required this.nombre,
    required this.descripcion,
    this.responsable,
    this.estado = 'Planificado',
    this.latitud,
    this.longitud,
    this.variedadPalma,
    this.cantidadPalmas,
    this.fechaInicio,
    this.fechaFin,
    this.fotoPath,
  });

  final int id;
  final String nombre;
  final String descripcion;
  final String? responsable;
  final String estado;
  final double? latitud;
  final double? longitud;
  final String? variedadPalma;
  final int? cantidadPalmas;
  final String? fechaInicio;
  final String? fechaFin;
  final String? fotoPath;
}

enum EstadoRecorrido { detenido, activo, pausado, finalizado }

class Recorrido {
  const Recorrido({
    required this.id,
    required this.proyectoId,
    required this.nombre,
    required this.estado,
    required this.inicio,
    this.fin,
  });

  final int id;
  final int proyectoId;
  final String nombre;
  final EstadoRecorrido estado;
  final DateTime inicio;
  final DateTime? fin;
}

class PuntosDatabase {
  static Database? _database;

  static Future<Database> get database async {
    final database = _database;
    if (database != null) return database;

    final databasesPath = await getDatabasesPath();
    final databasePath = path.join(databasesPath, 'coordenadas.db');
    _database = await openDatabase(
      databasePath,
      version: 13,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE puntos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nombre TEXT NOT NULL,
            tipo TEXT NOT NULL,
            latitud REAL NOT NULL,
            longitud REAL NOT NULL,
            altitud REAL NOT NULL,
            precision REAL NOT NULL,
            fecha TEXT NOT NULL,
            origen TEXT NOT NULL DEFAULT 'GPS'
            ,cantidad_palmas INTEGER
          )
        ''');
        await _crearTablasOrganizacion(database);
        await _crearTablaProyectos(database);
        await _crearProyectoPredeterminado(database);
        await _crearTablasRecorridos(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _crearTablasOrganizacion(database);
        }
        if (oldVersion < 3) {
          await database.execute(
            'ALTER TABLE segmentos ADD COLUMN vertices TEXT NOT NULL DEFAULT \'[]\'',
          );
        }
        if (oldVersion < 4) {
          await _crearTablaProyectos(database);
          await database.execute(
            'ALTER TABLE capas ADD COLUMN proyecto_id INTEGER NOT NULL DEFAULT 1',
          );
          await _crearProyectoPredeterminado(database);
        }
        if (oldVersion < 5) {
          await _agregarCamposAgronomicos(database);
        }
        if (oldVersion < 6) {
          await database.execute(
            "ALTER TABLE puntos ADD COLUMN origen TEXT NOT NULL DEFAULT 'GPS'",
          );
        }
        if (oldVersion < 7) {
          await _agregarCamposProyecto(database);
        }
        if (oldVersion < 8) {
          await _crearTablasRecorridos(database);
        }
        if (oldVersion < 9) {
          await database.execute(
            'ALTER TABLE recorridos ADD COLUMN proyecto_id INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (oldVersion < 10) {
          await _agregarCamposPuntosRecorrido(database);
        }
        if (oldVersion < 11) {
          await _agregarCamposPlantacion(database);
        }
        if (oldVersion < 12) {
          await _agregarNumeracionRegistros(database);
        }
        if (oldVersion < 13) {
          await database.execute(
            'ALTER TABLE puntos ADD COLUMN cantidad_palmas INTEGER',
          );
        }
      },
    );
    return _database!;
  }

  static Future<void> _crearTablasOrganizacion(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS capas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        proyecto_id INTEGER NOT NULL DEFAULT 1,
        nombre TEXT NOT NULL,
        descripcion TEXT NOT NULL DEFAULT ''
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS segmentos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        capa_id INTEGER NOT NULL,
        nombre TEXT NOT NULL,
        descripcion TEXT NOT NULL DEFAULT '',
        vertices TEXT NOT NULL DEFAULT '[]',
        area_m2 REAL,
        perimetro_m REAL,
        cantidad_palmas INTEGER,
        variedad TEXT,
        estado TEXT,
        ph_suelo REAL,
        FOREIGN KEY (capa_id) REFERENCES capas (id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _agregarCamposAgronomicos(Database database) async {
    for (final columna in [
      'area_m2 REAL',
      'perimetro_m REAL',
      'cantidad_palmas INTEGER',
      'variedad TEXT',
      'estado TEXT',
      'ph_suelo REAL',
    ]) {
      await database.execute('ALTER TABLE segmentos ADD COLUMN $columna');
    }
  }

  static Future<void> _crearTablaProyectos(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS proyectos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nombre TEXT NOT NULL,
        descripcion TEXT NOT NULL DEFAULT '',
        responsable TEXT,
        estado TEXT NOT NULL DEFAULT 'Planificado',
        latitud REAL,
        longitud REAL,
        fecha_inicio TEXT,
        fecha_fin TEXT,
        foto_path TEXT,
        variedad_palma TEXT,
        cantidad_palmas INTEGER
      )
    ''');
  }

  static Future<void> _agregarCamposProyecto(Database database) async {
    for (final columna in [
      'responsable TEXT',
      "estado TEXT NOT NULL DEFAULT 'Planificado'",
      'latitud REAL',
      'longitud REAL',
      'fecha_inicio TEXT',
      'fecha_fin TEXT',
      'foto_path TEXT',
    ]) {
      await database.execute('ALTER TABLE proyectos ADD COLUMN $columna');
    }
  }

  static Future<void> _agregarCamposPlantacion(Database database) async {
    await database.execute(
      'ALTER TABLE proyectos ADD COLUMN variedad_palma TEXT',
    );
    await database.execute(
      'ALTER TABLE proyectos ADD COLUMN cantidad_palmas INTEGER',
    );
  }

  static Future<void> _crearProyectoPredeterminado(Database database) async {
    final proyectos = await database.query('proyectos', limit: 1);
    if (proyectos.isEmpty) {
      await database.insert('proyectos', {
        'nombre': 'Plantación inicial',
        'descripcion': 'Plantación creada automáticamente',
      });
    }
  }

  static Future<List<Proyecto>> obtenerProyectos() async {
    final database = await PuntosDatabase.database;
    final rows = await database.query('proyectos', orderBy: 'id DESC');
    return rows
        .map(
          (row) => Proyecto(
            id: row['id']! as int,
            nombre: row['nombre']! as String,
            descripcion: row['descripcion']! as String,
            responsable: row['responsable'] as String?,
            estado: (row['estado'] as String?) ?? 'Planificado',
            latitud: (row['latitud'] as num?)?.toDouble(),
            longitud: (row['longitud'] as num?)?.toDouble(),
            variedadPalma: row['variedad_palma'] as String?,
            cantidadPalmas: row['cantidad_palmas'] as int?,
            fechaInicio: row['fecha_inicio'] as String?,
            fechaFin: row['fecha_fin'] as String?,
            fotoPath: row['foto_path'] as String?,
          ),
        )
        .toList();
  }

  static Future<int> guardarProyecto({
    required String nombre,
    required String descripcion,
    String? responsable,
    required String estado,
    double? latitud,
    double? longitud,
    String? variedadPalma,
    int? cantidadPalmas,
    String? fechaInicio,
    String? fechaFin,
    String? fotoPath,
  }) async {
    final database = await PuntosDatabase.database;
    return database.insert('proyectos', {
      'nombre': nombre,
      'descripcion': descripcion,
      'responsable': responsable,
      'estado': estado,
      'latitud': latitud,
      'longitud': longitud,
      'variedad_palma': variedadPalma,
      'cantidad_palmas': cantidadPalmas,
      'fecha_inicio': fechaInicio,
      'fecha_fin': fechaFin,
      'foto_path': fotoPath,
    });
  }

  static Future<void> actualizarDatosPlantacion({
    required int id,
    required String nombre,
    required int cantidadPalmas,
  }) async {
    final database = await PuntosDatabase.database;
    await database.update(
      'proyectos',
      {'nombre': nombre, 'cantidad_palmas': cantidadPalmas},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> eliminarPlantacion(int id) async {
    final database = await PuntosDatabase.database;
    await database.transaction((transaction) async {
      await transaction.delete(
        'recorrido_puntos',
        where:
            'recorrido_id IN '
            '(SELECT id FROM recorridos WHERE proyecto_id = ?)',
        whereArgs: [id],
      );
      await transaction.delete(
        'recorridos',
        where: 'proyecto_id = ?',
        whereArgs: [id],
      );
      await transaction.delete('proyectos', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> eliminarRecorrido(int id) async {
    final database = await PuntosDatabase.database;
    await database.transaction((transaction) async {
      await transaction.delete(
        'recorrido_puntos',
        where: 'recorrido_id = ?',
        whereArgs: [id],
      );
      await transaction.delete('recorridos', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> actualizarUbicacionPlantacion({
    required int id,
    required double latitud,
    required double longitud,
  }) async {
    final database = await PuntosDatabase.database;
    await database.update(
      'proyectos',
      {'latitud': latitud, 'longitud': longitud},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> _crearTablasRecorridos(Database database) async {
    await database.execute('''
    CREATE TABLE IF NOT EXISTS recorridos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      proyecto_id INTEGER NOT NULL,
      nombre TEXT NOT NULL,
      estado TEXT NOT NULL,
      inicio TEXT NOT NULL,
      fin TEXT
    )
  ''');
    await database.execute('''
    CREATE TABLE IF NOT EXISTS recorrido_puntos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      recorrido_id INTEGER NOT NULL,
      latitud REAL NOT NULL,
      longitud REAL NOT NULL,
      altitud REAL NOT NULL,
      precision REAL NOT NULL,
      fecha TEXT NOT NULL,
      racimos_verdes INTEGER,
      racimos_pintones INTEGER,
      inflorescencias INTEGER,
      foto_path TEXT,
      numero_registro INTEGER,
      FOREIGN KEY (recorrido_id) REFERENCES recorridos (id) ON DELETE CASCADE
    )
  ''');
  }

  static Future<void> _agregarCamposPuntosRecorrido(Database database) async {
    for (final columna in [
      'racimos_verdes INTEGER',
      'racimos_pintones INTEGER',
      'inflorescencias INTEGER',
      'foto_path TEXT',
    ]) {
      await database.execute(
        'ALTER TABLE recorrido_puntos ADD COLUMN $columna',
      );
    }
  }

  static Future<void> _agregarNumeracionRegistros(Database database) async {
    await database.execute(
      'ALTER TABLE recorrido_puntos ADD COLUMN numero_registro INTEGER',
    );
    final filas = await database.query(
      'recorrido_puntos',
      where:
          '(racimos_verdes IS NOT NULL OR racimos_pintones IS NOT NULL OR '
          'inflorescencias IS NOT NULL OR foto_path IS NOT NULL)',
      orderBy: 'recorrido_id, fecha, id',
    );
    var recorridoActual = -1;
    var numero = 0;
    for (final fila in filas) {
      final recorridoId = fila['recorrido_id']! as int;
      if (recorridoId != recorridoActual) {
        recorridoActual = recorridoId;
        numero = 0;
      }
      numero++;
      await database.update(
        'recorrido_puntos',
        {'numero_registro': numero},
        where: 'id = ?',
        whereArgs: [fila['id']],
      );
    }
  }

  static Future<int> crearRecorrido({
    required int proyectoId,
    required String nombre,
  }) async {
    final database = await PuntosDatabase.database;
    return database.insert('recorridos', {
      'proyecto_id': proyectoId,
      'nombre': nombre,
      'estado': 'activo',
      'inicio': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> actualizarEstadoRecorrido(
    int id,
    EstadoRecorrido estado, {
    DateTime? fin,
  }) async {
    final database = await PuntosDatabase.database;
    await database.update(
      'recorridos',
      {'estado': estado.name, if (fin != null) 'fin': fin.toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> guardarPuntoRecorrido({
    required int recorridoId,
    required Position posicion,
  }) async {
    final database = await PuntosDatabase.database;
    await database.insert('recorrido_puntos', {
      'recorrido_id': recorridoId,
      'latitud': posicion.latitude,
      'longitud': posicion.longitude,
      'altitud': posicion.altitude,
      'precision': posicion.accuracy,
      'fecha': posicion.timestamp.toIso8601String(),
    });
  }

  static Future<void> guardarPuntoInicialRecorrido({
    required int proyectoId,
    required int recorridoId,
    required Position posicion,
  }) async {
    final database = await PuntosDatabase.database;
    await database.transaction((transaction) async {
      final puntoId = await transaction.insert('recorrido_puntos', {
        'recorrido_id': recorridoId,
        'latitud': posicion.latitude,
        'longitud': posicion.longitude,
        'altitud': posicion.altitude,
        'precision': posicion.accuracy,
        'fecha': posicion.timestamp.toIso8601String(),
      });
      final puntoGuardado = (await transaction.query(
        'recorrido_puntos',
        columns: ['latitud', 'longitud'],
        where: 'id = ?',
        whereArgs: [puntoId],
      )).single;
      await transaction.update(
        'proyectos',
        {
          'latitud': puntoGuardado['latitud'],
          'longitud': puntoGuardado['longitud'],
        },
        where: 'id = ? AND (latitud IS NULL OR longitud IS NULL)',
        whereArgs: [proyectoId],
      );
    });
  }

  static Future<void> guardarRegistroRecorrido({
    required int recorridoId,
    required Position posicion,
    int? racimosVerdes,
    int? racimosPintones,
    int? inflorescencias,
    String? fotoPath,
  }) async {
    final database = await PuntosDatabase.database;
    final ultimoRegistro = await database.rawQuery(
      'SELECT COALESCE(MAX(numero_registro), 0) AS numero '
      'FROM recorrido_puntos WHERE recorrido_id = ?',
      [recorridoId],
    );
    final numeroRegistro = (ultimoRegistro.first['numero']! as num).toInt() + 1;
    await database.insert('recorrido_puntos', {
      'recorrido_id': recorridoId,
      'latitud': posicion.latitude,
      'longitud': posicion.longitude,
      'altitud': posicion.altitude,
      'precision': posicion.accuracy,
      'fecha': posicion.timestamp.toIso8601String(),
      'racimos_verdes': racimosVerdes,
      'racimos_pintones': racimosPintones,
      'inflorescencias': inflorescencias,
      'foto_path': fotoPath,
      'numero_registro': numeroRegistro,
    });
  }

  static Future<List<LatLng>> obtenerPuntosRecorrido(int id) async {
    final database = await PuntosDatabase.database;
    final filas = await database.query(
      'recorrido_puntos',
      where: 'recorrido_id = ?',
      whereArgs: [id],
      orderBy: 'fecha',
    );
    return filas
        .map(
          (fila) => LatLng(
            (fila['latitud']! as num).toDouble(),
            (fila['longitud']! as num).toDouble(),
          ),
        )
        .toList();
  }

  static Future<int> contarRegistrosRecorrido(int id) async {
    final database = await PuntosDatabase.database;
    final resultado = await database.rawQuery(
      'SELECT COUNT(*) AS total FROM recorrido_puntos '
      'WHERE recorrido_id = ? AND numero_registro IS NOT NULL',
      [id],
    );
    return (resultado.first['total']! as int);
  }

  static Future<List<Map<String, Object?>>> obtenerRegistrosRecorrido(
    int id,
  ) async {
    final database = await PuntosDatabase.database;
    return database.query(
      'recorrido_puntos',
      where:
          'recorrido_id = ? AND '
          'numero_registro IS NOT NULL',
      whereArgs: [id],
      orderBy: 'fecha',
    );
  }

  static Future<List<Recorrido>> obtenerRecorridos(int proyectoId) async {
    final database = await PuntosDatabase.database;
    final filas = await database.query(
      'recorridos',
      where: 'proyecto_id = ?',
      whereArgs: [proyectoId],
      orderBy: 'id DESC',
    );
    return filas
        .map(
          (fila) => Recorrido(
            id: fila['id']! as int,
            proyectoId: fila['proyecto_id']! as int,
            nombre: fila['nombre']! as String,
            estado: EstadoRecorrido.values.firstWhere(
              (item) => item.name == fila['estado'],
              orElse: () => EstadoRecorrido.finalizado,
            ),
            inicio: DateTime.parse(fila['inicio']! as String),
            fin: fila['fin'] == null
                ? null
                : DateTime.parse(fila['fin']! as String),
          ),
        )
        .toList();
  }
}

class ResumenTransferenciaPlantacion {
  const ResumenTransferenciaPlantacion({
    required this.nombre,
    required this.cantidadRecorridos,
    required this.cantidadPuntos,
  });

  final String nombre;
  final int cantidadRecorridos;
  final int cantidadPuntos;
}

class TransferenciaPlantacion {
  static const String _formato = 'coordenadas_plantacion';
  static const int _version = 1;

  static Future<Uint8List> exportar(int proyectoId) async {
    final database = await PuntosDatabase.database;
    final plantacion = (await database.query(
      'proyectos',
      where: 'id = ?',
      whereArgs: [proyectoId],
      limit: 1,
    )).first;
    final proyecto = Map<String, Object?>.from(plantacion);
    await _incluirFoto(proyecto);

    final recorridos = await database.query(
      'recorridos',
      where: 'proyecto_id = ?',
      whereArgs: [proyectoId],
      orderBy: 'id',
    );
    final recorridosExportados = <Map<String, Object?>>[];
    for (final recorrido in recorridos) {
      final puntos = await database.query(
        'recorrido_puntos',
        where: 'recorrido_id = ?',
        whereArgs: [recorrido['id']],
        orderBy: 'fecha, id',
      );
      final puntosExportados = <Map<String, Object?>>[];
      for (final punto in puntos) {
        final puntoExportado = Map<String, Object?>.from(punto);
        await _incluirFoto(puntoExportado);
        puntosExportados.add(puntoExportado);
      }
      recorridosExportados.add({
        'recorrido': Map<String, Object?>.from(recorrido),
        'puntos': puntosExportados,
      });
    }
    final json = jsonEncode({
      'format': _formato,
      'version': _version,
      'exported_at': DateTime.now().toIso8601String(),
      'project': proyecto,
      'routes': recorridosExportados,
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  static Future<void> _incluirFoto(Map<String, Object?> fila) async {
    final fotoPath = fila['foto_path'] as String?;
    fila['foto_path'] = null;
    if (fotoPath == null) return;

    final file = File(fotoPath);
    if (!await file.exists()) {
      throw FileSystemException(
        'No se encontro una evidencia guardada',
        fotoPath,
      );
    }
    fila['foto_file_name'] = path.basename(fotoPath);
    fila['foto_base64'] = base64Encode(await file.readAsBytes());
  }

  static ResumenTransferenciaPlantacion previsualizar(Uint8List bytes) {
    final root = _decodificar(bytes);
    final proyecto = _mapa(root['project'], 'plantación');
    final nombre = proyecto['nombre'];
    if (nombre is! String || nombre.trim().isEmpty) {
      throw const FormatException(
        'El archivo no contiene un nombre de plantación válido.',
      );
    }
    final recorridos = root['routes'];
    if (recorridos is! List) {
      throw const FormatException(
        'El archivo no contiene una lista válida de recorridos.',
      );
    }
    var totalPuntos = 0;
    for (final entrada in recorridos) {
      final grupo = _mapa(entrada, 'recorrido');
      _mapa(grupo['recorrido'], 'datos del recorrido');
      final puntos = grupo['puntos'];
      if (puntos is! List) {
        throw const FormatException(
          'Un recorrido contiene una lista de puntos inválida.',
        );
      }
      totalPuntos += puntos.length;
      for (final punto in puntos) {
        _validarPunto(_mapa(punto, 'punto'));
      }
    }
    return ResumenTransferenciaPlantacion(
      nombre: nombre,
      cantidadRecorridos: recorridos.length,
      cantidadPuntos: totalPuntos,
    );
  }

  static Future<int> importar(Uint8List bytes) async {
    previsualizar(bytes);
    final root = _decodificar(bytes);
    final proyectoOrigen = _mapa(root['project'], 'plantación');
    final grupos = (root['routes'] as List)
        .map((entrada) => _mapa(entrada, 'recorrido'))
        .toList();
    final fotosCreadas = <File>[];
    var contadorFoto = 0;

    Future<String?> restaurarFoto(Map<String, Object?> fila) async {
      final encoded = fila['foto_base64'];
      if (encoded == null) return null;
      if (encoded is! String || encoded.isEmpty) {
        throw const FormatException('Una evidencia fotográfica está dañada.');
      }
      final bytesFoto = base64Decode(encoded);
      final nombreOrigen = fila['foto_file_name'] as String? ?? '';
      final extensionOrigen = path.extension(nombreOrigen);
      final extension =
          RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(extensionOrigen)
          ? extensionOrigen.toLowerCase()
          : '.bin';
      final directorio = Directory(
        path.join(
          (await getApplicationDocumentsDirectory()).path,
          'evidencias_importadas',
        ),
      );
      await directorio.create(recursive: true);
      contadorFoto++;
      final archivo = File(
        path.join(
          directorio.path,
          'evidencia_${DateTime.now().microsecondsSinceEpoch}_$contadorFoto$extension',
        ),
      );
      await archivo.writeAsBytes(bytesFoto, flush: true);
      fotosCreadas.add(archivo);
      return archivo.path;
    }

    try {
      final proyectoFoto = await restaurarFoto(proyectoOrigen);
      final recorridosPreparados =
          <
            ({
              Map<String, Object?> datos,
              List<({Map<String, Object?> datos, String? fotoPath})> puntos,
            })
          >[];
      for (final grupo in grupos) {
        final datosRecorrido = _mapa(grupo['recorrido'], 'datos del recorrido');
        final estado = datosRecorrido['estado'];
        if (estado is! String ||
            !EstadoRecorrido.values.any((item) => item.name == estado)) {
          throw const FormatException('Un recorrido tiene un estado inválido.');
        }
        final puntos = <({Map<String, Object?> datos, String? fotoPath})>[];
        for (final puntoValue in grupo['puntos'] as List) {
          final punto = _mapa(puntoValue, 'punto');
          _validarPunto(punto);
          puntos.add((datos: punto, fotoPath: await restaurarFoto(punto)));
        }
        recorridosPreparados.add((datos: datosRecorrido, puntos: puntos));
      }

      final database = await PuntosDatabase.database;
      return await database.transaction((transaction) async {
        final proyectoId = await transaction.insert('proyectos', {
          'nombre': proyectoOrigen['nombre'],
          'descripcion': proyectoOrigen['descripcion'] ?? '',
          'responsable': proyectoOrigen['responsable'],
          'estado': proyectoOrigen['estado'] ?? 'Planificado',
          'latitud': proyectoOrigen['latitud'],
          'longitud': proyectoOrigen['longitud'],
          'fecha_inicio': proyectoOrigen['fecha_inicio'],
          'fecha_fin': proyectoOrigen['fecha_fin'],
          'foto_path': proyectoFoto,
          'variedad_palma': proyectoOrigen['variedad_palma'],
          'cantidad_palmas': proyectoOrigen['cantidad_palmas'],
        });
        for (final grupo in recorridosPreparados) {
          final estadoOrigen = grupo.datos['estado'] as String;
          final estadoImportado =
              estadoOrigen == EstadoRecorrido.activo.name ||
                  estadoOrigen == EstadoRecorrido.pausado.name
              ? EstadoRecorrido.detenido.name
              : estadoOrigen;
          final recorridoId = await transaction.insert('recorridos', {
            'proyecto_id': proyectoId,
            'nombre': grupo.datos['nombre'],
            'estado': estadoImportado,
            'inicio': grupo.datos['inicio'],
            'fin': grupo.datos['fin'],
          });
          for (final punto in grupo.puntos) {
            await transaction.insert('recorrido_puntos', {
              'recorrido_id': recorridoId,
              'latitud': punto.datos['latitud'],
              'longitud': punto.datos['longitud'],
              'altitud': punto.datos['altitud'],
              'precision': punto.datos['precision'],
              'fecha': punto.datos['fecha'],
              'racimos_verdes': punto.datos['racimos_verdes'],
              'racimos_pintones': punto.datos['racimos_pintones'],
              'inflorescencias': punto.datos['inflorescencias'],
              'foto_path': punto.fotoPath,
              'numero_registro': punto.datos['numero_registro'],
            });
          }
        }
        return proyectoId;
      });
    } catch (_) {
      for (final file in fotosCreadas) {
        if (await file.exists()) await file.delete();
      }
      rethrow;
    }
  }

  static Map<String, Object?> _decodificar(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    final root = _mapa(decoded, 'archivo');
    if (root['format'] != _formato || root['version'] != _version) {
      throw const FormatException(
        'El archivo no es compatible con esta aplicación.',
      );
    }
    return root;
  }

  static Map<String, Object?> _mapa(Object? value, String nombre) {
    if (value is! Map) {
      throw FormatException('El archivo contiene datos inválidos en $nombre.');
    }
    return Map<String, Object?>.from(value);
  }

  static void _validarPunto(Map<String, Object?> punto) {
    final latitud = punto['latitud'];
    final longitud = punto['longitud'];
    final altitud = punto['altitud'];
    final precision = punto['precision'];
    if (latitud is! num ||
        longitud is! num ||
        altitud is! num ||
        precision is! num ||
        !latitud.isFinite ||
        !longitud.isFinite ||
        latitud < -90 ||
        latitud > 90 ||
        longitud < -180 ||
        longitud > 180 ||
        punto['fecha'] is! String) {
      throw const FormatException(
        'El archivo contiene coordenadas o puntos inválidos.',
      );
    }
  }
}

class ExportadorDatos {
  static Future<void> compartirRecorridoExcel(int recorridoId) async {
    final database = await PuntosDatabase.database;
    final recorrido = (await database.query(
      'recorridos',
      where: 'id = ?',
      whereArgs: [recorridoId],
      limit: 1,
    )).first;
    final plantacion = (await database.query(
      'proyectos',
      where: 'id = ?',
      whereArgs: [recorrido['proyecto_id']],
      limit: 1,
    )).first;
    final filas = await database.query(
      'recorrido_puntos',
      where: 'recorrido_id = ? AND numero_registro IS NOT NULL',
      whereArgs: [recorridoId],
      orderBy: 'numero_registro, fecha',
    );
    final libro = Excel.createExcel();
    final hoja = libro['Recorrido'];
    hoja.appendRow([
      TextCellValue('N° registro'),
      TextCellValue('ID del registro'),
      TextCellValue('Plantación'),
      TextCellValue('Recorrido'),
      TextCellValue('Latitud'),
      TextCellValue('Longitud'),
      TextCellValue('Altitud'),
      TextCellValue('Precisión'),
      TextCellValue('Fecha'),
      TextCellValue('Racimos verdes'),
      TextCellValue('Racimos pintones'),
      TextCellValue('Inflorescencias'),
    ]);
    for (final fila in filas) {
      hoja.appendRow([
        IntCellValue((fila['numero_registro'] as int?) ?? 0),
        IntCellValue((fila['id'] as int?) ?? 0),
        TextCellValue('${plantacion['nombre']}'),
        TextCellValue('${recorrido['nombre']}'),
        DoubleCellValue((fila['latitud']! as num).toDouble()),
        DoubleCellValue((fila['longitud']! as num).toDouble()),
        DoubleCellValue((fila['altitud']! as num).toDouble()),
        DoubleCellValue((fila['precision']! as num).toDouble()),
        TextCellValue('${fila['fecha']}'),
        IntCellValue((fila['racimos_verdes'] as int?) ?? 0),
        IntCellValue((fila['racimos_pintones'] as int?) ?? 0),
        IntCellValue((fila['inflorescencias'] as int?) ?? 0),
      ]);
    }
    final bytes = libro.encode();
    if (bytes == null) {
      throw StateError('No se pudo generar el archivo Excel.');
    }
    await _compartir(
      Uint8List.fromList(bytes),
      'recorrido_$recorridoId.xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  static Future<void> compartirRecorridoKml(int recorridoId) async {
    final database = await PuntosDatabase.database;
    final recorrido = (await database.query(
      'recorridos',
      where: 'id = ?',
      whereArgs: [recorridoId],
      limit: 1,
    )).first;
    final filas = await database.query(
      'recorrido_puntos',
      where: 'recorrido_id = ?',
      whereArgs: [recorridoId],
      orderBy: 'fecha',
    );
    final coordenadas = filas
        .map(
          (fila) => '${fila['longitud']},${fila['latitud']},${fila['altitud']}',
        )
        .join(' ');
    final registros = filas.where(
      (fila) =>
          fila['racimos_verdes'] != null ||
          fila['racimos_pintones'] != null ||
          fila['inflorescencias'] != null,
    );
    final marcas = registros
        .map(
          (fila) =>
              '''
    <Placemark>
      <name>Registro ${_xml(fila['numero_registro'])}</name>
      <description><![CDATA[
        Registro: ${_xml(fila['numero_registro'])}<br/>
        Racimos verdes: ${_xml(fila['racimos_verdes'] ?? 0)}<br/>
        Racimos pintones: ${_xml(fila['racimos_pintones'] ?? 0)}<br/>
        Inflorescencias: ${_xml(fila['inflorescencias'] ?? 0)}<br/>
        Fecha: ${_xml(fila['fecha'])}
      ]]></description>
      <Point><coordinates>${fila['longitud']},${fila['latitud']},${fila['altitud']}</coordinates></Point>
    </Placemark>
  ''',
        )
        .join();
    final kml =
        '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>${_xml(recorrido['nombre'])}</name>
    <Placemark>
      <name>Ruta</name>
      <LineString><tessellate>1</tessellate><coordinates>$coordenadas</coordinates></LineString>
    </Placemark>
    $marcas
  </Document>
</kml>
''';
    await _compartir(
      Uint8List.fromList(utf8.encode(kml)),
      'recorrido_$recorridoId.kml',
      'application/vnd.google-earth.kml+xml',
    );
  }

  static String _xml(Object? value) => '${value ?? ''}'
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static Future<void> _compartir(
    Uint8List bytes,
    String nombre,
    String tipo,
  ) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: nombre, mimeType: tipo)],
        subject: nombre,
        text: 'Exportación de coordenadas',
      ),
    );
  }
}

class ProyectosPage extends StatefulWidget {
  const ProyectosPage({super.key});

  @override
  State<ProyectosPage> createState() => _ProyectosPageState();
}

class _ProyectosPageState extends State<ProyectosPage> {
  List<Proyecto> _proyectos = [];
  final Map<int, List<Recorrido>> _recorridosPorPlantacion = {};
  bool _cargando = true;
  bool _creando = false;
  bool _abriendoRecorrido = false;
  bool _transfiriendo = false;
  final Set<int> _plantacionesEnCurso = {};
  final Set<int> _recorridosEnCurso = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargarProyectos();
  }

  Future<void> _cargarProyectos() async {
    if (!_esDispositivoMovil) {
      setState(() {
        _cargando = false;
        _error = 'Los proyectos se guardan localmente en Android.';
      });
      return;
    }
    try {
      final proyectos = await PuntosDatabase.obtenerProyectos();
      if (!mounted) return;
      final recorridos = <int, List<Recorrido>>{};
      for (final proyecto in proyectos) {
        recorridos[proyecto.id] = await PuntosDatabase.obtenerRecorridos(
          proyecto.id,
        );
      }
      if (!mounted) return;
      setState(() {
        _proyectos = proyectos;
        _recorridosPorPlantacion
          ..clear()
          ..addAll(recorridos);
        _cargando = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudieron cargar los proyectos: $error';
      });
    }
  }

  bool get _esDispositivoMovil =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _compartirPlantacion(Proyecto proyecto) async {
    if (_transfiriendo || !mounted) return;
    setState(() => _transfiriendo = true);
    try {
      final bytes = await TransferenciaPlantacion.exportar(proyecto.id);
      final directorio = await getTemporaryDirectory();
      final nombreSeguro = proyecto.nombre.trim().replaceAll(
        RegExp(r'[^A-Za-z0-9_-]+'),
        '_',
      );
      final archivo = File(
        path.join(
          directorio.path,
          'plantacion_${nombreSeguro.isEmpty ? proyecto.id : nombreSeguro}.json',
        ),
      );
      await archivo.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              archivo.path,
              mimeType: 'application/json',
              name: path.basename(archivo.path),
            ),
          ],
          subject: 'Plantación ${proyecto.nombre}',
          text:
              'Copia de la plantación y sus recorridos para importar '
              'en Coordenadas.',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo compartir la plantación: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _transfiriendo = false);
    }
  }

  Future<void> _importarPlantacion() async {
    if (_transfiriendo || !mounted) return;
    setState(() => _transfiriendo = true);
    try {
      final archivo = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (archivo == null || !mounted) return;
      final bytes = await archivo.readAsBytes();
      if (!mounted) return;
      final resumen = TransferenciaPlantacion.previsualizar(bytes);
      final confirmar = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Importar plantación'),
          content: Text(
            'Se agregará una copia nueva de "${resumen.nombre}" con '
            '${resumen.cantidadRecorridos} recorridos y '
            '${resumen.cantidadPuntos} puntos/registros. '
            'No se sobrescribirán los datos existentes.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(true),
              child: const Text('Importar copia'),
            ),
          ],
        ),
      );
      if (confirmar != true || !mounted) return;
      final id = await TransferenciaPlantacion.importar(bytes);
      await _cargarProyectos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '"${resumen.nombre}" y sus datos se importaron correctamente.',
            ),
            action: SnackBarAction(
              label: 'Ver',
              onPressed: () {
                final imported = _proyectos.where((item) => item.id == id);
                if (imported.isNotEmpty) {
                  _abrirRecorrido(imported.first);
                }
              },
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo importar la plantación: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _transfiriendo = false);
    }
  }

  Future<void> _crearProyecto() async {
    if (_creando || !mounted) return;
    setState(() => _creando = true);
    try {
      final datos = await _pedirDatosProyecto();
      if (datos == null || !_esDispositivoMovil || !mounted) return;
      await PuntosDatabase.guardarProyecto(
        nombre: datos.nombre,
        descripcion: '',
        estado: 'Planificado',
        cantidadPalmas: datos.cantidadPalmas,
      );
      await _cargarProyectos();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar la plantación: $error')),
      );
    } finally {
      if (mounted) setState(() => _creando = false);
    }
  }

  Future<void> _abrirRecorrido(Proyecto proyecto) async {
    if (_abriendoRecorrido || !mounted) return;
    setState(() => _abriendoRecorrido = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecorridosPage(proyecto: proyecto),
        ),
      );
    } finally {
      if (mounted) setState(() => _abriendoRecorrido = false);
    }
  }

  Future<void> _editarDatosPlantacion(Proyecto proyecto) async {
    final datos = await _pedirDatosProyecto(proyecto: proyecto);
    if (datos != null && mounted) {
      try {
        await PuntosDatabase.actualizarDatosPlantacion(
          id: proyecto.id,
          nombre: datos.nombre,
          cantidadPalmas: datos.cantidadPalmas,
        );
        await _cargarProyectos();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No se pudo actualizar la plantación: $error'),
            ),
          );
        }
      }
    }
  }

  Future<void> _eliminarPlantacion(Proyecto proyecto) async {
    if (_plantacionesEnCurso.contains(proyecto.id)) return;
    final recorridos = _recorridosPorPlantacion[proyecto.id] ?? [];
    final confirmar = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar plantación'),
        content: Text(
          '¿Eliminar "${proyecto.nombre}" y sus ${recorridos.length} '
          'recorridos con todos sus puntos? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(true),
            child: const Text('Eliminar todo'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    setState(() => _plantacionesEnCurso.add(proyecto.id));
    try {
      await PuntosDatabase.eliminarPlantacion(proyecto.id);
      await _cargarProyectos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Plantación "${proyecto.nombre}" eliminada.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo eliminar la plantación: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _plantacionesEnCurso.remove(proyecto.id));
    }
  }

  Future<void> _eliminarRecorrido(
    Proyecto proyecto,
    Recorrido recorrido,
  ) async {
    if (_recorridosEnCurso.contains(recorrido.id)) return;
    final confirmar = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar recorrido'),
        content: Text(
          '¿Eliminar "${recorrido.nombre}" y todos sus puntos y registros? '
          'Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    setState(() => _recorridosEnCurso.add(recorrido.id));
    try {
      await PuntosDatabase.eliminarRecorrido(recorrido.id);
      await _cargarProyectos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recorrido "${recorrido.nombre}" eliminado.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo eliminar el recorrido: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _recorridosEnCurso.remove(recorrido.id));
    }
  }

  String _estadoTextoRecorrido(EstadoRecorrido estado) {
    switch (estado) {
      case EstadoRecorrido.activo:
        return 'Activo';
      case EstadoRecorrido.pausado:
        return 'Pausado';
      case EstadoRecorrido.finalizado:
        return 'Finalizado';
      case EstadoRecorrido.detenido:
        return 'Detenido';
    }
  }

  Future<({String nombre, int cantidadPalmas})?> _pedirDatosProyecto({
    Proyecto? proyecto,
  }) async {
    if (!mounted) return null;
    var nombre = proyecto?.nombre ?? '';
    var cantidadTexto = proyecto?.cantidadPalmas?.toString() ?? '';
    return showDialog<({String nombre, int cantidadPalmas})>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, dialogSetState) => AlertDialog(
          title: Text(
            proyecto == null ? 'Nueva plantación' : 'Editar plantación',
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    autofocus: true,
                    initialValue: nombre,
                    onChanged: (value) => nombre = value,
                    decoration: const InputDecoration(
                      labelText: 'Nombre *',
                      hintText: 'Ej. Hacienda La Esperanza',
                    ),
                  ),
                  TextFormField(
                    initialValue: cantidadTexto,
                    keyboardType: TextInputType.number,
                    onChanged: (value) => cantidadTexto = value,
                    decoration: const InputDecoration(
                      labelText: 'Cantidad de palmas *',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final nombreFinal = nombre.trim();
                if (nombreFinal.isEmpty) {
                  return;
                }
                final cantidad = int.tryParse(cantidadTexto.trim());
                if (cantidad == null || cantidad < 0) {
                  return;
                }
                Navigator.of(
                  dialogContext,
                  rootNavigator: true,
                ).pop((nombre: nombreFinal, cantidadPalmas: cantidad));
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plantaciones'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Recibir plantación desde archivo',
            onPressed: _transfiriendo ? null : _importarPlantacion,
            icon: const Icon(Icons.file_open),
          ),
          IconButton(
            tooltip: 'Nueva plantación',
            onPressed: _esDispositivoMovil && !_creando ? _crearProyecto : null,
            icon: const Icon(Icons.create_new_folder),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : _proyectos.isEmpty
          ? Center(
              child: FilledButton.icon(
                onPressed: _creando ? null : _crearProyecto,
                icon: const Icon(Icons.add),
                label: const Text('Crear primer proyecto'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _proyectos.length,
              itemBuilder: (context, index) {
                final proyecto = _proyectos[index];
                final recorridos = _recorridosPorPlantacion[proyecto.id] ?? [];
                return Card(
                  child: ExpansionTile(
                    initiallyExpanded: true,
                    leading: const Icon(Icons.agriculture),
                    title: Text(proyecto.nombre),
                    subtitle: Text(
                      [
                        if (proyecto.cantidadPalmas != null)
                          'Palmas: ${proyecto.cantidadPalmas}',
                        if (proyecto.latitud != null &&
                            proyecto.longitud != null)
                          'Ubicación generada',
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      tooltip: 'Editar plantación',
                      onPressed: () => _editarDatosPlantacion(proyecto),
                      icon: const Icon(Icons.edit),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _transfiriendo
                                ? null
                                : () => _compartirPlantacion(proyecto),
                            icon: const Icon(Icons.share),
                            label: const Text('Enviar plantación y registros'),
                          ),
                        ),
                      ),
                      if (recorridos.isEmpty)
                        const ListTile(
                          dense: true,
                          leading: Icon(Icons.route_outlined),
                          title: Text('Sin recorridos'),
                          subtitle: Text(
                            'Abre la plantación para iniciar el primero.',
                          ),
                        )
                      else
                        ...recorridos.map(
                          (recorrido) => ListTile(
                            dense: true,
                            leading: Icon(
                              recorrido.estado == EstadoRecorrido.activo
                                  ? Icons.gps_fixed
                                  : Icons.route,
                              color: recorrido.estado == EstadoRecorrido.activo
                                  ? Colors.green
                                  : null,
                            ),
                            title: Text(recorrido.nombre),
                            subtitle: Text(
                              'Estado: ${_estadoTextoRecorrido(recorrido.estado)}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Eliminar recorrido y sus puntos',
                              onPressed:
                                  _recorridosEnCurso.contains(recorrido.id)
                                  ? null
                                  : () =>
                                        _eliminarRecorrido(proyecto, recorrido),
                              icon: const Icon(Icons.delete_outline),
                              color: Theme.of(context).colorScheme.error,
                            ),
                            onTap: _abriendoRecorrido
                                ? null
                                : () => _abrirRecorrido(proyecto),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed:
                                _plantacionesEnCurso.contains(proyecto.id)
                                ? null
                                : () => _eliminarPlantacion(proyecto),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text(
                              'Eliminar plantación y recorridos',
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .error,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _abriendoRecorrido
                                ? null
                                : () => _abrirRecorrido(proyecto),
                            icon: const Icon(Icons.route),
                            label: Text(
                              recorridos.isEmpty
                                  ? 'Iniciar recorrido'
                                  : 'Abrir recorridos',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: _proyectos.isEmpty || !_esDispositivoMovil
          ? null
          : FloatingActionButton.extended(
              onPressed: _creando ? null : _crearProyecto,
              icon: const Icon(Icons.add),
              label: const Text('Nueva plantación'),
            ),
    );
  }
}

class RecorridosPage extends StatefulWidget {
  const RecorridosPage({required this.proyecto, super.key});

  final Proyecto proyecto;

  @override
  State<RecorridosPage> createState() => _RecorridosPageState();
}

class _RecorridosPageState extends State<RecorridosPage>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _suscripcion;
  StreamSubscription<CompassEvent>? _suscripcionRumbo;
  List<Recorrido> _recorridos = [];
  List<LatLng> _ruta = [];
  List<Map<String, Object?>> _puntosMuestreo = [];
  Recorrido? _actual;
  Recorrido? _recorridoEnCurso;
  int? _recorridoSeleccionadoId;
  Position? _ultimaPosicion;
  LatLng? _coordenadaSeleccionada;
  double? _rumbo;
  double _zoomMapa = 19;
  double _latitudMapa = 4.7110;
  int _registrosMuestreo = 0;
  bool _cargando = true;
  bool _iniciandoRecorrido = false;
  bool _registrandoMuestreo = false;
  bool _disposed = false;
  String? _error;
  Timer? _temporizadorCamara;
  Timer? _temporizadorCiudades;
  final http.Client _clienteCiudades = http.Client();
  List<CityMapLabel> _ciudades = [];
  String? _consultaCiudadesActual;
  int _solicitudCiudades = 0;
  bool _avisoCiudadesMostrado = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepararMosaicosOffline());
    WidgetsBinding.instance.addObserver(this);
    _cargarRecorridos();
  }

  @override
  void dispose() {
    _disposed = true;
    _temporizadorCamara?.cancel();
    _temporizadorCiudades?.cancel();
    _clienteCiudades.close();
    WidgetsBinding.instance.removeObserver(this);
    final subscription = _suscripcion;
    _suscripcion = null;
    unawaited(subscription?.cancel());
    unawaited(_suscripcionRumbo?.cancel());
    _suscripcionRumbo = null;
    super.dispose();
  }

  Future<void> _prepararMosaicosOffline() async {
    try {
      await EsriImageryTileProvider.prepare();
      if (mounted && !_disposed) setState(() {});
    } catch (error) {
      if (mounted && !_disposed) {
        _mostrarAviso('No se pudo preparar la caché del mapa: $error');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_disposed) {
      _reanudarRecorridoAlVolver();
    }
  }

  Future<void> _reanudarRecorridoAlVolver() async {
    await _cargarRecorridos();
    final recorrido = _recorridoEnCurso;
    if (!mounted ||
        _disposed ||
        recorrido == null ||
        recorrido.estado != EstadoRecorrido.activo ||
        _suscripcion != null) {
      return;
    }
    try {
      if (await _prepararUbicacion()) {
        _suscribirUbicacion();
      }
    } catch (error) {
      if (mounted) {
        _mostrarAviso('No se pudo reanudar el GPS: $error');
      }
    }
  }

  Future<void> _mostrarRecorrido(Recorrido recorrido) async {
    if (!mounted || _disposed) return;
    _recorridoSeleccionadoId = recorrido.id;
    setState(() {
      _actual = recorrido;
    });
    _ruta = await PuntosDatabase.obtenerPuntosRecorrido(recorrido.id);
    _puntosMuestreo = await PuntosDatabase.obtenerRegistrosRecorrido(
      recorrido.id,
    );
    _registrosMuestreo = await PuntosDatabase.contarRegistrosRecorrido(
      recorrido.id,
    );
    if (_ruta.isNotEmpty) {
      final ultima = _ruta.last;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_disposed) {
          _moverMapa(ultima, 19);
        }
      });
    }
    if (!_disposed &&
        !_iniciandoRecorrido &&
        _recorridoEnCurso?.estado == EstadoRecorrido.activo &&
        _suscripcion == null) {
      _suscribirUbicacion();
    }
    if (mounted) setState(() {});
  }

  Future<void> _cargarRecorridos() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'Los recorridos se guardan localmente en Android.';
      });
      return;
    }
    try {
      final recorridos = await PuntosDatabase.obtenerRecorridos(
        widget.proyecto.id,
      );
      if (!mounted) return;
      Recorrido? enCurso;
      for (final item in recorridos) {
        if (item.estado == EstadoRecorrido.activo ||
            item.estado == EstadoRecorrido.pausado) {
          enCurso = item;
          break;
        }
      }
      Recorrido? seleccion;
      if (_recorridoSeleccionadoId != null) {
        for (final item in recorridos) {
          if (item.id == _recorridoSeleccionadoId) {
            seleccion = item;
            break;
          }
        }
      }
      seleccion ??= enCurso;
      seleccion ??= recorridos.isEmpty ? null : recorridos.first;
      setState(() {
        _recorridos = recorridos;
        _recorridoEnCurso = enCurso;
        _cargando = false;
      });
      if (seleccion != null) {
        await _mostrarRecorrido(seleccion);
      } else {
        _actual = null;
        _recorridoSeleccionadoId = null;
        _ruta = [];
        _puntosMuestreo = [];
        _registrosMuestreo = 0;
        if (mounted) setState(() {});
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = 'No se pudieron cargar los recorridos: $error';
      });
    }
  }

  Future<bool> _prepararUbicacion() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted || _disposed) return false;
      _mostrarAviso('Activa el servicio de ubicación.');
      return false;
    }
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (!mounted || _disposed) return false;
    if (permiso == LocationPermission.denied ||
        permiso == LocationPermission.deniedForever) {
      _mostrarAviso('Se necesita permiso de ubicación para recorrer.');
      return false;
    }
    return true;
  }

  Future<void> _iniciarRecorrido() async {
    if (_iniciandoRecorrido || !mounted || _disposed) return;
    setState(() => _iniciandoRecorrido = true);
    try {
      final nombre = await _pedirNombreRecorrido();
      if (nombre == null || !mounted || _disposed) return;
      if (!await _prepararUbicacion()) return;
      if (!mounted || _disposed) return;
      final posicionInicial = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 30),
        ),
      );
      if (!mounted || _disposed) return;
      final id = await PuntosDatabase.crearRecorrido(
        proyectoId: widget.proyecto.id,
        nombre: nombre,
      );
      final recorridos = await PuntosDatabase.obtenerRecorridos(
        widget.proyecto.id,
      );
      final recorridoCreado = recorridos.firstWhere((item) => item.id == id);
      _actual = recorridoCreado;
      _recorridoEnCurso = recorridoCreado;
      _recorridoSeleccionadoId = id;
      _ruta = [];
      if (mounted) setState(() => _recorridos = recorridos);
      _ultimaPosicion = posicionInicial;
      await PuntosDatabase.guardarPuntoInicialRecorrido(
        proyectoId: widget.proyecto.id,
        recorridoId: id,
        posicion: posicionInicial,
      );
      final puntoInicial = LatLng(
        posicionInicial.latitude,
        posicionInicial.longitude,
      );
      _ruta = [puntoInicial];
      _moverMapa(puntoInicial, 19);
      if (mounted) setState(() {});
      _suscribirUbicacion();
    } catch (error) {
      if (mounted) _mostrarAviso('No se pudo iniciar el recorrido: $error');
    } finally {
      if (mounted) setState(() => _iniciandoRecorrido = false);
    }
  }

  Future<void> _registrarMuestreo() async {
    if (_registrandoMuestreo || !mounted || _disposed) return;
    final recorrido = _recorridoEnCurso;
    if (recorrido == null || recorrido.estado != EstadoRecorrido.activo) {
      _mostrarAviso('Inicia o reanuda el recorrido para registrar un punto.');
      return;
    }

    setState(() => _registrandoMuestreo = true);
    try {
      final registro = await _pedirDatosMuestreo();
      if (!mounted || _disposed || registro == null) return;

      if (registro.racimosVerdes == null &&
          registro.racimosPintones == null &&
          registro.inflorescencias == null &&
          registro.fotoPath == null) {
        _mostrarAviso('Ingresa al menos un dato o adjunta una evidencia.');
        return;
      }

      final posicion = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted || _disposed) return;

      await PuntosDatabase.guardarRegistroRecorrido(
        recorridoId: recorrido.id,
        posicion: posicion,
        racimosVerdes: registro.racimosVerdes,
        racimosPintones: registro.racimosPintones,
        inflorescencias: registro.inflorescencias,
        fotoPath: registro.fotoPath,
      );
      if (!mounted || _disposed) return;

      _puntosMuestreo = await PuntosDatabase.obtenerRegistrosRecorrido(
        recorrido.id,
      );
      _registrosMuestreo = await PuntosDatabase.contarRegistrosRecorrido(
        recorrido.id,
      );

      if (!mounted || _disposed) return;
      setState(() {});
      _mostrarAviso('Registro guardado en la ubicación actual.');
    } catch (error) {
      if (mounted && !_disposed) {
        _mostrarAviso('No se pudo guardar el registro: $error');
      }
    } finally {
      if (mounted && !_disposed) {
        setState(() => _registrandoMuestreo = false);
      }
    }
  }

  Future<
    ({
      int? racimosVerdes,
      int? racimosPintones,
      int? inflorescencias,
      String? fotoPath,
    })?
  >
  _pedirDatosMuestreo() async {
    if (!mounted || _disposed) return null;

    String verdes = '';
    String pintones = '';
    String inflorescencias = '';
    String? fotoPath;
    return showDialog<
      ({
        int? racimosVerdes,
        int? racimosPintones,
        int? inflorescencias,
        String? fotoPath,
      })
    >(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Registro del punto'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  keyboardType: TextInputType.number,
                  onChanged: (value) => verdes = value,
                  decoration: const InputDecoration(
                    labelText: 'Racimos verdes',
                  ),
                ),
                TextFormField(
                  keyboardType: TextInputType.number,
                  onChanged: (value) => pintones = value,
                  decoration: const InputDecoration(
                    labelText: 'Racimos pintones',
                  ),
                ),
                TextFormField(
                  keyboardType: TextInputType.number,
                  onChanged: (value) => inflorescencias = value,
                  decoration: const InputDecoration(
                    labelText: 'Inflorescencias',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final foto = await ImagePicker().pickImage(
                      source: ImageSource.camera,
                      imageQuality: 85,
                    );
                    if (!dialogContext.mounted || foto == null) return;
                    setDialogState(() => fotoPath = foto.path);
                  },
                  icon: const Icon(Icons.camera_alt),
                  label: Text(
                    fotoPath == null ? 'Adjuntar evidencia' : 'Foto adjunta',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext, rootNavigator: true).pop((
                    racimosVerdes: int.tryParse(verdes.trim()),
                    racimosPintones: int.tryParse(pintones.trim()),
                    inflorescencias: int.tryParse(inflorescencias.trim()),
                    fotoPath: fotoPath,
                  )),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  void _suscribirUbicacion() {
    final previous = _suscripcion;
    _suscripcion = null;
    unawaited(previous?.cancel());
    final subscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen((posicion) async {
          _ultimaPosicion = posicion;
          final recorrido = _actual;
          if (!mounted ||
              _disposed ||
              recorrido == null ||
              recorrido.estado != EstadoRecorrido.activo) {
            return;
          }

          try {
            await PuntosDatabase.guardarPuntoRecorrido(
              recorridoId: recorrido.id,
              posicion: posicion,
            );
            if (!mounted || _disposed) return;
            final punto = LatLng(posicion.latitude, posicion.longitude);
            if (_actual?.id != recorrido.id) return;
            setState(() {
              if (_ruta.isEmpty ||
                  _ruta.last.latitude != punto.latitude ||
                  _ruta.last.longitude != punto.longitude) {
                _ruta = [..._ruta, punto];
              }
            });
            if (!mounted || _disposed) return;
            _moverMapa(punto, 19);
          } catch (error) {
            if (mounted && !_disposed) {
              _mostrarAviso('No se pudo guardar la posición: $error');
            }
          }
        });
    if (!mounted || _disposed) {
      unawaited(subscription.cancel());
      return;
    }
    _suscripcion = subscription;
    _suscribirseBrujula();
  }

  void _suscribirseBrujula() {
    if (_suscripcionRumbo != null || _disposed) return;
    final eventos = FlutterCompass.events;
    if (eventos == null) return;
    _suscripcionRumbo = eventos.listen(_actualizarRumbo);
  }

  void _actualizarRumbo(CompassEvent evento) {
    final rumbo = evento.heading;
    if (!mounted || _disposed || rumbo == null) return;
    setState(() => _rumbo = rumbo);
  }

  void _actualizarVistaMapa(MapCamera camera, bool hasGesture) {
    if (!mounted || _disposed) return;
    _programarActualizacionCamara(camera.zoom, camera.center.latitude);
    _programarCargaCiudades(camera);
  }

  void _programarCargaCiudades(MapCamera camera) {
    _temporizadorCiudades?.cancel();
    _temporizadorCiudades = Timer(const Duration(milliseconds: 450), () {
      unawaited(_cargarCiudades(camera));
    });
  }

  Future<void> _cargarCiudades(MapCamera camera) async {
    if (!mounted || _disposed) return;
    if (CityMapLabel.maxPopulationRank(camera.zoom) == null) {
      _consultaCiudadesActual = null;
      _solicitudCiudades++;
      if (_ciudades.isNotEmpty) setState(() => _ciudades = []);
      return;
    }
    final bounds = camera.visibleBounds;
    final consulta = [
      bounds.west.toStringAsFixed(3),
      bounds.south.toStringAsFixed(3),
      bounds.east.toStringAsFixed(3),
      bounds.north.toStringAsFixed(3),
      CityMapLabel.maxPopulationRank(camera.zoom),
    ].join(',');
    if (_consultaCiudadesActual == consulta) return;
    _consultaCiudadesActual = consulta;
    final solicitud = ++_solicitudCiudades;
    try {
      final ciudades = await CityMapLabel.load(
        client: _clienteCiudades,
        bounds: bounds,
        zoom: camera.zoom,
      );
      if (!mounted || _disposed || solicitud != _solicitudCiudades) return;
      setState(() => _ciudades = ciudades);
    } catch (error) {
      if (!mounted || _disposed || solicitud != _solicitudCiudades) return;
      _consultaCiudadesActual = null;
      if (!_avisoCiudadesMostrado) {
        _avisoCiudadesMostrado = true;
        _mostrarAviso('No se pudieron cargar los nombres de ciudades: $error');
      }
    }
  }

  Marker _marcadorCiudad(CityMapLabel ciudad) => Marker(
    point: LatLng(ciudad.latitude, ciudad.longitude),
    width: 150,
    height: 28,
    alignment: Alignment.center,
    child: IgnorePointer(
      child: Text(
        ciudad.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(color: Colors.black, blurRadius: 3),
            Shadow(color: Colors.black, blurRadius: 5),
          ],
        ),
      ),
    ),
  );

  void _programarActualizacionCamara(double zoom, double latitud) {
    _temporizadorCamara?.cancel();
    _temporizadorCamara = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _disposed) return;
      setState(() {
        _zoomMapa = zoom;
        _latitudMapa = latitud;
      });
    });
  }

  void _moverMapa(LatLng punto, double zoom) {
    _mapController.move(punto, zoom);
  }

  void _seleccionarCoordenada(TapPosition _, LatLng punto) {
    if (!mounted || _disposed) return;
    setState(() => _coordenadaSeleccionada = punto);
  }

  Future<void> _pausar() async {
    final recorrido = _actual;
    if (recorrido == null ||
        recorrido.estado != EstadoRecorrido.activo ||
        _recorridoEnCurso?.id != recorrido.id) {
      return;
    }
    try {
      final subscription = _suscripcion;
      _suscripcion = null;
      await subscription?.cancel();
      await PuntosDatabase.actualizarEstadoRecorrido(
        recorrido.id,
        EstadoRecorrido.pausado,
      );
      if (mounted) await _cargarRecorridos();
    } catch (error) {
      if (mounted) _mostrarAviso('No se pudo pausar el recorrido: $error');
    }
  }

  Future<void> _reanudar() async {
    try {
      final recorrido = _actual;
      if (recorrido == null ||
          recorrido.estado != EstadoRecorrido.pausado ||
          !await _prepararUbicacion()) {
        return;
      }
      await PuntosDatabase.actualizarEstadoRecorrido(
        recorrido.id,
        EstadoRecorrido.activo,
      );
      if (!mounted) return;
      await _cargarRecorridos();
      if (mounted) _suscribirUbicacion();
    } catch (error) {
      if (mounted) _mostrarAviso('No se pudo reanudar el recorrido: $error');
    }
  }

  Future<void> _finalizar() async {
    try {
      final recorrido = _actual;
      if (recorrido == null) return;
      final subscription = _suscripcion;
      _suscripcion = null;
      await subscription?.cancel();
      await PuntosDatabase.actualizarEstadoRecorrido(
        recorrido.id,
        EstadoRecorrido.finalizado,
        fin: DateTime.now(),
      );
      if (!mounted) return;
      _recorridoEnCurso = null;
      _recorridoSeleccionadoId = recorrido.id;
      await _cargarRecorridos();
    } catch (error) {
      if (mounted) _mostrarAviso('No se pudo finalizar el recorrido: $error');
    }
  }

  Future<void> _exportarRecorrido(
    Future<void> Function() exportador,
    String formato,
  ) async {
    try {
      await exportador();
      if (mounted) {
        _mostrarAviso('$formato generado correctamente.');
      }
    } catch (error) {
      if (mounted) {
        _mostrarAviso('No se pudo generar $formato: $error');
      }
    }
  }

  Future<String?> _pedirNombreRecorrido() async {
    if (!mounted || _disposed) return null;

    var nombre = 'Recorrido ${_recorridos.length + 1}';
    return showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nuevo recorrido'),
        content: TextFormField(
          initialValue: nombre,
          autofocus: true,
          onChanged: (value) => nombre = value,
          decoration: const InputDecoration(labelText: 'Nombre *'),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final valor = nombre.trim();
              if (valor.isEmpty) return;
              Navigator.of(dialogContext, rootNavigator: true).pop(valor);
            },
            child: const Text('Iniciar'),
          ),
        ],
      ),
    );
  }

  void _mostrarAviso(String mensaje) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(mensaje)));
  }

  String _estadoTexto(EstadoRecorrido estado) {
    switch (estado) {
      case EstadoRecorrido.activo:
        return 'Activo';
      case EstadoRecorrido.pausado:
        return 'Pausado';
      case EstadoRecorrido.finalizado:
        return 'Finalizado';
      case EstadoRecorrido.detenido:
        return 'Detenido';
    }
  }

  Color _colorEstadoRecorrido(EstadoRecorrido estado) {
    switch (estado) {
      case EstadoRecorrido.activo:
        return Colors.green;
      case EstadoRecorrido.pausado:
        return Colors.orange;
      case EstadoRecorrido.finalizado:
        return Colors.blueGrey;
      case EstadoRecorrido.detenido:
        return Colors.grey;
    }
  }

  IconData _iconoEstadoRecorrido(EstadoRecorrido estado) {
    switch (estado) {
      case EstadoRecorrido.activo:
        return Icons.radio_button_checked;
      case EstadoRecorrido.pausado:
        return Icons.pause_circle_outline;
      case EstadoRecorrido.finalizado:
        return Icons.check_circle_outline;
      case EstadoRecorrido.detenido:
        return Icons.cancel_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final recorrido = _actual;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.proyecto.nombre),
            const Text('Recorridos', style: TextStyle(fontSize: 12)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Nuevo recorrido',
            onPressed: _iniciandoRecorrido ? null : _iniciarRecorrido,
            icon: const Icon(Icons.add_road),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      flex: 3,
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: LatLng(4.7110, -74.0721),
                          initialZoom: 6,
                          maxZoom: 24,
                          backgroundColor: const Color(0xFF53624F),
                          onMapReady: () =>
                              _programarCargaCiudades(_mapController.camera),
                          onPositionChanged: _actualizarVistaMapa,
                          onTap: _seleccionarCoordenada,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: '${OfflineTileStore.url}/{z}/{y}/{x}',
                            userAgentPackageName: 'com.example.coordenadas_app',
                            maxNativeZoom: 23,
                            tileProvider: EsriImageryTileProvider(),
                          ),
                          MarkerLayer(
                            markers: _ciudades.map(_marcadorCiudad).toList(),
                          ),
                          if (_ruta.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _ruta,
                                  color: Colors.blue,
                                  strokeWidth: 5,
                                ),
                              ],
                            ),
                          if (_ultimaPosicion != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: LatLng(
                                    _ultimaPosicion!.latitude,
                                    _ultimaPosicion!.longitude,
                                  ),
                                  width: 64,
                                  height: 64,
                                  child: _MarcadorUbicacion(
                                    rumbo: _rumbo ?? _ultimaPosicion!.heading,
                                    precision: _ultimaPosicion!.accuracy,
                                  ),
                                ),
                              ],
                            ),
                          if (_coordenadaSeleccionada != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _coordenadaSeleccionada!,
                                  width: 42,
                                  height: 42,
                                  child: const Icon(
                                    Icons.add_location_alt,
                                    color: Colors.red,
                                    size: 36,
                                  ),
                                ),
                              ],
                            ),
                          if (_coordenadaSeleccionada != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _coordenadaSeleccionada!,
                                  width: 42,
                                  height: 42,
                                  child: const Icon(
                                    Icons.add_location_alt,
                                    color: Colors.red,
                                    size: 36,
                                  ),
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: _puntosMuestreo.map((punto) {
                              final latitud = (punto['latitud']! as num)
                                  .toDouble();
                              final longitud = (punto['longitud']! as num)
                                  .toDouble();
                              final verdes = punto['racimos_verdes'];
                              final pintones = punto['racimos_pintones'];
                              final inflorescencias = punto['inflorescencias'];
                              final tieneFoto = punto['foto_path'] != null;
                              final numero = punto['numero_registro'] as int?;
                              return Marker(
                                point: LatLng(latitud, longitud),
                                width: 32,
                                height: 32,
                                child: Tooltip(
                                  message: [
                                    'Punto de registro',
                                    if (verdes != null) 'Verdes: $verdes',
                                    if (pintones != null) 'Pintones: $pintones',
                                    if (inflorescencias != null)
                                      'Inflorescencias: $inflorescencias',
                                    if (tieneFoto) 'Con evidencia fotográfica',
                                  ].join('\n'),
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: tieneFoto
                                          ? Colors.orangeAccent
                                          : Colors.deepOrange,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 4,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      numero != null ? '$numero' : '',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          RichAttributionWidget(
                            attributions: [
                              TextSourceAttribution(
                                'Source: Esri, Vantor, Earthstar Geographics, '
                                'and the GIS User Community. City names: Esri '
                                'World Cities data.',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_recorridos.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _recorridos.map((recorridoItem) {
                              final seleccionado =
                                  _actual?.id == recorridoItem.id;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  avatar: Icon(
                                    _iconoEstadoRecorrido(recorridoItem.estado),
                                    size: 18,
                                    color: _colorEstadoRecorrido(
                                      recorridoItem.estado,
                                    ),
                                  ),
                                  label: Text(
                                    recorridoItem.nombre.isNotEmpty
                                        ? recorridoItem.nombre
                                        : 'Recorrido ${recorridoItem.id}',
                                  ),
                                  selected: seleccionado,
                                  selectedColor: _colorEstadoRecorrido(
                                    recorridoItem.estado,
                                  ).withValues(alpha: 0.18),
                                  onSelected: (_) {
                                    if (!seleccionado) {
                                      _mostrarRecorrido(recorridoItem);
                                    }
                                  },
                                  showCheckmark: false,
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    _IndicadorVistaMapa(zoom: _zoomMapa, latitud: _latitudMapa),
                    _IndicadorBrujula(
                      rumbo: _rumbo ?? _ultimaPosicion?.heading,
                    ),
                    if (recorrido != null)
                      Card(
                        margin: const EdgeInsets.all(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                recorrido.nombre,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Row(
                                children: [
                                  Icon(
                                    _iconoEstadoRecorrido(recorrido.estado),
                                    size: 18,
                                    color: _colorEstadoRecorrido(
                                      recorrido.estado,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Estado: ${_estadoTexto(recorrido.estado)}',
                                    style: TextStyle(
                                      color: _colorEstadoRecorrido(
                                        recorrido.estado,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              if (recorrido.estado ==
                                      EstadoRecorrido.finalizado &&
                                  recorrido.fin != null)
                                Text(
                                  'Finalizado: ${recorrido.fin!.toLocal().toString().substring(0, 16)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              Text('Puntos registrados: ${_ruta.length}'),
                              Text(
                                'Registros de plantación: $_registrosMuestreo',
                              ),
                              const SizedBox(height: 8),
                              if (recorrido.estado == EstadoRecorrido.activo ||
                                  recorrido.estado ==
                                      EstadoRecorrido.pausado) ...[
                                const Text(
                                  'Acciones del recorrido',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (recorrido.estado ==
                                        EstadoRecorrido.activo)
                                      FilledButton.icon(
                                        onPressed: _registrandoMuestreo
                                            ? null
                                            : _registrarMuestreo,
                                        icon: const Icon(Icons.forest),
                                        label: const Text('Registrar punto'),
                                      ),
                                    if (recorrido.estado ==
                                        EstadoRecorrido.activo)
                                      FilledButton.icon(
                                        onPressed: _pausar,
                                        icon: const Icon(Icons.pause),
                                        label: const Text('Pausar'),
                                      ),
                                    if (recorrido.estado ==
                                        EstadoRecorrido.pausado)
                                      FilledButton.icon(
                                        onPressed: _reanudar,
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text('Reanudar'),
                                      ),
                                    OutlinedButton.icon(
                                      onPressed: _finalizar,
                                      icon: const Icon(Icons.stop),
                                      label: const Text('Finalizar'),
                                    ),
                                  ],
                                ),
                              ] else if (recorrido.estado ==
                                  EstadoRecorrido.finalizado)
                                const Text(
                                  'Recorrido finalizado · vista de consulta',
                                  style: TextStyle(color: Colors.blueGrey),
                                ),
                              const Divider(),
                              const Text(
                                'Exportar',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => _exportarRecorrido(
                                      () =>
                                          ExportadorDatos.compartirRecorridoExcel(
                                            recorrido.id,
                                          ),
                                      'el Excel de registros',
                                    ),
                                    icon: const Icon(Icons.table_view),
                                    label: const Text('Registros Excel'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => _exportarRecorrido(
                                      () =>
                                          ExportadorDatos.compartirRecorridoKml(
                                            recorrido.id,
                                          ),
                                      'el KML del recorrido',
                                    ),
                                    icon: const Icon(Icons.public),
                                    label: const Text('Ruta y registros KML'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: FilledButton.icon(
                          onPressed: _iniciandoRecorrido
                              ? null
                              : _iniciarRecorrido,
                          icon: const Icon(Icons.route),
                          label: const Text('Iniciar recorrido'),
                        ),
                      ),
                  ],
                ),
                if (_iniciandoRecorrido || _registrandoMuestreo)
                  const _CargandoOperacion(mensaje: 'Guardando información...'),
              ],
            ),
    );
  }
}
