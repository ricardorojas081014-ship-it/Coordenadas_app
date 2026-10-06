# Coordenadas

Aplicación Flutter para registrar plantaciones, ubicaciones y recorridos.

## Mapa satelital

Los mapas principal y de recorridos usan **Esri World Imagery**, sin requerir
clave de API. La descarga de zonas guarda los mosaicos para uso sin conexión y
conserva las descargas anteriores en el mismo directorio de caché. Se puede
centrar cada descarga en un punto marcado en el mapa, la ubicación actual o
coordenadas ingresadas en una sola línea (`latitud, longitud`, por ejemplo
`7.89, -72.50`), y elegir el tamaño del área. Se descargan las teselas de zoom
17; al acercar sin conexión,
la app prioriza el mosaico guardado y amplía su imagen hasta el zoom disponible
en el mapa; esto no agrega detalle que no estuviera en la descarga. Una capa de
datos separada muestra únicamente nombres de ciudades; no superpone carreteras
ni nombres de vías. Esos nombres se solicitan al servicio Esri World Cities al
mover o acercar el mapa, y no están disponibles sin conexión.

La capa satelital prueba la tesela nativa para cada área hasta zoom 23. Si Esri
responde que no hay imagen disponible, la app baja nivel por nivel hasta hallar
la tesela más cercana con imagen y recorta su sección correspondiente. Así usa
el último nivel que sí tiene datos para esa ubicación, en lugar de mostrar
"Data not available". Se puede acercar hasta zoom 24; después del último nivel
disponible para el área la imagen se amplía, lo que no crea detalle nuevo y
puede pixelarse. La capa de nombres se carga separadamente para que las
etiquetas permanezcan legibles.

La atribución se muestra en el mapa: **Source: Esri, Vantor, Earthstar
Geographics, and the GIS User Community**; los nombres de ciudades provienen
del servicio **Esri World Cities**.
Consulta los términos de Esri para los usos y la redistribución de la
cartografía.

## Ejecutar

```sh
flutter pub get
flutter run
```
