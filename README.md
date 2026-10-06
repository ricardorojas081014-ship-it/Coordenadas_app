# Coordenadas

Aplicación Flutter para registrar plantaciones, ubicaciones y recorridos.

## Mapa satelital

Los mapas principal y de recorridos usan **Esri World Imagery**, sin requerir
clave de API. La descarga de zonas guarda los mosaicos para uso sin conexión y
conserva las descargas anteriores en el mismo directorio de caché. Una capa
transparente de referencia de Esri añade nombres de pueblos, ciudades, lugares
y límites sobre las imágenes; las etiquetas se cargan por internet y no forman
parte de los mosaicos descargados para uso sin conexión.

La capa satelital prueba la tesela nativa para cada área hasta zoom 23. Si Esri
responde que no hay imagen disponible, la app baja nivel por nivel hasta hallar
la tesela más cercana con imagen y recorta su sección correspondiente. Así usa
el último nivel que sí tiene datos para esa ubicación, en lugar de mostrar
"Data not available". Se puede acercar hasta zoom 24; después del último nivel
disponible para el área la imagen se amplía, lo que no crea detalle nuevo y
puede pixelarse. La capa de nombres se carga separadamente para que las
etiquetas permanezcan legibles.

La atribución se muestra en el mapa: **Source: Esri, Vantor, Earthstar
Geographics, and the GIS User Community**; las etiquetas atribuyen a **Esri,
HERE, Garmin, OpenStreetMap contributors, and the GIS user community**.
Consulta los términos de Esri para los usos y la redistribución de la
cartografía.

## Ejecutar

```sh
flutter pub get
flutter run
```
