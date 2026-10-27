# Espacio de propiedades: diseño aprobado

Estado: implementación y verificación automatizada completadas; validación
interactiva pendiente. Referencia: mockup aprobado
el 25 de octubre de 2026, sin contador inferior de propiedades.

## Comportamiento

- La ventana usa un único `NavigationSplitView`. El grupo Propiedades de su
  lista nativa contiene Todas las casas, Paseo de los Parques y las propiedades
  configuradas. Ambas casas usan el mismo `Label` de casa y selección nativa.
- El espacio comparte título, mes, pestañas, indicadores, aportaciones y datos
  de composición. La presentación recibe valores adaptados del cálculo de
  Household o del registro de propiedades, conservando sus reglas existentes.
- Las secciones son Resumen, Liquidación, Movimientos y Configuración. Las
  propiedades con registro de mantenimiento ofrecen además Mantenimiento.
- El consolidado suma gastos reales del periodo y muestra obligaciones,
  cobros recibidos y recuperación de Fer con etiquetas que distinguen su origen.
  No agrega esos importes a los indicadores financieros personales.
- El mes se conserva al cambiar de casa. Un destino eliminado vuelve al
  consolidado. La selección de una casa o pestaña no escribe datos financieros.
- Los importes, tablas y formularios se adaptan al ancho. La barra lateral
  tiene ancho nativo ajustable de 200–300 puntos y puede ocultarse.

## Estado y datos

`PropertyWorkspaceModel` es la fuente de estado del destino, mes, registro,
errores y reportes. Lee el JSON fuera del actor principal y comparte la carga
entre solicitudes concurrentes. Lee metadatos de vencimientos y obtiene los
movimientos del periodo, fuentes históricas vinculadas y vencimientos de Fer
con una consulta de transacciones. Las selecciones y ediciones de ingresos
reutilizan ese conjunto; una modificación externa o cambio de mes lo invalida.

El adaptador usa los cálculos actuales, incluidos vencimientos futuros y
anteriores. No modifica el esquema SwiftData ni el formato de respaldo. Los
fallos de lectura bloquean escrituras; los fallos de guardado restauran la copia
anterior en memoria y presentan un error. No se crean propiedades, personas o
movimientos de ejemplo. Las pruebas sintéticas usan memoria o rutas temporales.

## Aceptación y evidencia

- Una sola barra lateral; filas equivalentes y ausencia del contador inferior.
- Ambas casas y el consolidado conservan el mes y navegan con teclado.
- Las secciones de ambas casas muestran contenido, estados vacíos y errores
  recuperables. Ninguna navegación crea una configuración mensual vacía.
- Pruebas de destino eliminado/renombrado, caché por periodo, adaptadores,
  movimientos históricos, cuentas vacías y errores de disco.
- Pruebas enfocadas, suite serial, build Debug canónico y comprobaciones de
  dinero, localización y whitespace antes de la entrega.
- Medición con 1,000 gastos en memoria y observación en AppKit; perfilado de la
  app Dev y validación visual en ventanas amplias y estrechas. El intervalo
  `Property interaction to draw` termina en el primer dibujo de AppKit, no solo
  al finalizar un cálculo; no representa una medición de presentación GPU.

## Evidencia del 25 de octubre de 2026

Comandos ejecutados en este checkout, sin modificar el entorno de producción:

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -configuration Debug build
plutil -lint FinanceTracker/es-MX.lproj/Localizable.strings
git diff --check
```

- Última suite serial: **630 pruebas / 74 suites, 0 fallos, 13.149 s**;
  `TEST SUCCEEDED`. Incluye Propiedades, Household, respaldo, reinicio,
  dashboard e ingestión. La selección enfocada inicial tuvo 69 pruebas sin
  fallos; la selección posterior del espacio y Household tuvo 59 sin fallos.
- Build Debug canónico: `BUILD SUCCEEDED`, sin `-derivedDataPath`. No se
  preparó una versión ni se instaló o abrió la aplicación de producción.
- Dinero: búsqueda de `Double`/`Float` en Domain sin coincidencias ejecutables;
  localización `plutil` correcta y `git diff --check` limpio.
- Datos representativos: 1,000 gastos y tres residentes, creados únicamente en
  memoria. Consulta y cálculo: **103.31 ms**; primer layout/dibujo fuera de
  pantalla del resumen: **45.37 ms**. La carga cede ejecución cada 64
  movimientos y conserva una consulta por periodo, incluso con fuentes
  históricas conocidas como faltantes. Estas cifras no equivalen a latencia
  visible y no demuestran que se haya alcanzado el objetivo de 100 ms.
- Revisión visual preliminar en Dev: una sola lista, mismas filas y secciones
  compartidas; ventanas de aproximadamente 901 y 1656 puntos de ancho; cambio
  de casa conservando el mes; contenido y estados vacíos de configuración,
  liquidación y mantenimiento. Esta inspección precede a las últimas
  correcciones; no se presenta como validación visual final.
- Se capturó un perfil Time Profiler de 20 s de FinanceTracker Dev durante la
  investigación. Las primeras mediciones nativas fueron aproximadamente
  **171 ms** al abrir el espacio y **110 ms** al abrir una sección: el objetivo
  de respuesta visible inferior a 100 ms **no está acreditado**.

### Revisión independiente

Se ejecutaron procesos Codex independientes de solo lectura, con autorización
expresa del usuario para compartir el diff privado y sus fuentes relacionadas.
La revisión encontró y se corrigieron: cambios rechazados pendientes de
SwiftData, lecturas atrasadas del ledger, guardados diferidos de valores
revertidos, copias de reportes obsoletas, reintento con caché vieja,
normalización de configuración heredada al navegar, reportes de otro periodo
tras fallos, borradores inválidos presentados como guardados y configuración
perdida visualmente al no haber cuentas. Las regresiones de datos, concurrencia
y persistencia se cubren con pruebas aisladas.

La tercera revisión no encontró defectos de código BLOCKING o IMPORTANT;
se corrigió además su hallazgo menor en la vista previa independiente de
Household al revertir una edición. La revisión independiente del diff final no encontró defectos concretos de
código sin resolver. El revisor no ejecutó los comandos: el resultado final de
630 pruebas y el build canónico fueron verificados directamente por el agente
implementador después de los dos últimos ajustes. La revisión estática no
acredita las comprobaciones interactivas.

### Pendiente: pantalla y respuesta visible

El usuario pidió suspender capturas y automatización de ventanas porque
interfieren con la reproducción de video protegido. La sesión de automatización
se reinició y no se reanudará hasta que el usuario confirme disponibilidad. La
regla queda registrada en `AGENTS.md`. Continúan únicamente código, builds y
verificaciones que no capturan el escritorio.

Quedan pendientes la comprobación visual final, tamaños adicionales, teclado,
VoiceOver, apariencia oscura y ajustes de accesibilidad, más la optimización y
medición nativa que acredite el objetivo de respuesta. El estado **no** es
READY FOR DEVELOPMENT VALIDATION. La aprobación del diseño no autoriza una
versión o instalación.
