# Correcciones y evidencia de #27–#30

## Estado

Correcciones implementadas en las cuatro ramas apiladas. Se conservan como
drafts. Estado de entrega: verificación automatizada aprobada; rendimiento
visual y revisión independiente adicional pendientes. No se declara READY FOR
DEVELOPMENT VALIDATION ni se autoriza release o instalación.

No se lanzó, modificó ni instaló la app de producción. Las pruebas usan fixtures
sintéticos, contenedores en memoria, archivos temporales y un store temporal en
disco que se cierra y vuelve a abrir. Sin cambios al esquema SwiftData ni a la
versión de la app. Backup sigue en manifest 11 en #30 (10 en #27–#29).

## Cambios por PR

- **#27:** meta editable sin formato monetario, parser que exige consumir el
  texto completo y conserva precisión Decimal; límites de ventana opcionales
  independientes y rechazo de rangos invertidos. Errores de fetch son un estado
  indisponible; recargas diferidas por guardados de modelos y ledger. Retiro de
  huérfanos con error/reintento y diagnósticos de normalización visibles. Índice
  de badges calculado una vez por recarga, en lugar de una vez por fila.
- **#27 y #30:** timestamps nuevos estrictamente crecientes por entidad a
  precisión de segundos, incluidos tombstones. Empates históricos de mismo ID
  y fecha con contenido distinto conservan local y retornan advertencia. Restore
  valida antes de mutar, usa contexto dedicado sin autosave, prepara statements
  nuevos y publica JSONs staged antes de guardar. Fallos revierten modelos y
  bytes originales; no publican notificaciones de éxito. Fallos de compensación
  retornan error con ubicación de originales recuperables, guardados antes de
  publicar. El llamador con borradores pendientes se rechaza sin descartarlos.
- **#28:** preferencia de última captura exitosa por cuenta; sin historial de
  preferencia, hoy. Se actualiza después del save de transacciones/transferencias
  y antes de adjudicar. El selector marca intención explícita en su binding.
  Ediciones antiguas y cancelaciones no cambian la preferencia; no se consulta el
  historial completo. UserDefaults separados por bundle Dev/producción; tests
  usan su propio dominio. Reset y replaceAll exitosos limpian la preferencia.
- **#29:** header y filas comparten métricas y reservan la columna de promoción
  aunque esté vacía. Títulos de una línea sin limitar Dynamic Type. Preview con
  filas de 0, 1 y 12 promociones y tamaño accessibility2.
- **#30:** origen seed inmutable por UUID con padre/tipo; aliases conservados al
  reconstruir el mapa para reglas y al canonicalizar duplicados. Sueldo e
  intereses consultan identidad semántica; cálculo Household recibe un mapa de
  nombres como entrada, manteniendo el calculador puro. Python conserva el
  snapshot original y añade semanticName a su vista derivada para resolver reglas
  MSI. Renombres exactos no escriben; duplicados normalizados se rechazan;
  fallos de save compensan JSON y nombre. Estado observable compartido para
  colores. Personalización corrupta suspende bootstrap dependiente de aliases,
  muestra aviso/reintento y permite configurar Dashboard; reset elimina el
  archivo antes de bootstrap.

## Verificación automatizada

Código acumulado probado en `70cda6a`; la propagación final `2cfff9b` tiene el
mismo árbol de código. Rama base #27 verificada en `4fb8f88`.

| Verificación | Resultado |
|---|---|
| Suite Swift acumulada, serial | **582 tests / 72 suites**, 11.793 s |
| Suite Swift #27, serial | **562 tests / 69 suites**, 10.580 s |
| Regresiones reforzadas restore/rename/editor | **36 tests / 3 suites**, 2.188 s |
| Captura manual #28, suite enfocada | **23 tests / 1 suite** |
| Regresiones de categorías + medición opt-in | **6 tests / 2 suites**, 5.002 s |
| pytest completo | **101 passed**, 0.86 s |
| Build Debug canónico acumulado | **BUILD SUCCEEDED** |
| diff --check y guardia Double/Float en Domain | Limpios |

Comandos principales ejecutados:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -configuration Debug build
poetry run pytest
git diff main...HEAD --check
rg -n '\b(Double|Float)\b' FinanceTracker/Domain
```

Se regeneró el proyecto mediante xcodegen al agregar Swift files. Xcode emite
avisos por plugins CoreDevice/iOSSimulator del entorno; la compilación y los
tests macOS terminaron correctamente. No se ejecutó un nuevo build Release.

La prueba de restore inyecta fallo después de cada publicación, después de
preparar statements y en el callback del save. Cubre replace/merge; verifica
bytes de los tres sidecars, retirada de statements nuevos, contexto llamador
sin cambios pendientes y conservación de la cuenta al reabrir el store en
disco. No induce un fallo físico del disco: el callback del save lanza un error
para ejercitar el mismo manejo. Una prueba adicional hace fallar realmente la
compensación sustituyendo el destino por un directorio y verifica originales
recuperables. Se conservan pruebas de compatibilidad y round-trip de backups
legacy, manifest 9, 10 y 11.

## Rendimiento: operaciones de datos

Fixture sintético: 10,000 movimientos, 5 cuentas, 1,000 adjudicaciones. Build
Debug, actor principal, contenedor en memoria y sidecars temporales. 25 muestras
por operación; el resultado mide llamadas completas, sin renderizado SwiftUI.

| Operación | Mediana ms | Máximo ms |
|---|---:|---:|
| Leer fecha de captura | 0.034 | 0.073 |
| Filtrar por cuenta 10,000 filas ya cargadas | 24.999 | 47.294 |
| Recargar ledger y 1,000 transacciones adjudicadas | 47.557 | 50.369 |
| Adjudicar y retirar una transacción, ledger de 1,000 | 27.010 | 27.881 |
| Escribir color, recargar índice observable y retirar color | 1.341 | 1.901 |

Reproducción:

```sh
TEST_RUNNER_PR_CHAIN_PERFORMANCE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:FinanceTrackerTests/PRChainPerformanceTests -only-testing:FinanceTrackerTests/CategoryIdentityRegressionTests
```

Estos tiempos no prueban el primer frame <100 ms. La medición de filtro cubre
selección de cuenta sobre datos cacheados, no agrupación, ordenación ni layout.
La apertura completa de captura, cambios de filtros, adjudicación y cambio de
color deben verificarse con Time Profiler/Animation Hitches y datos aislados en
la app Dev canónica. LOOPS §8 exige dejar este punto explícitamente pendiente.

## Revisión y validación restantes

Se hizo una pasada propia de lógica y estándares, incluyendo búsqueda de
consumidores por nombre, orden de reset y propagación de bases. No es revisión
independiente: no hay herramienta de subagentes disponible en esta sesión.
LOOPS §9 requiere otra revisión en contexto independiente.

Checklist manual ampliado, solo en desarrollo con datos sintéticos:

1. Crear Platinum de 100,000 MXN, ventana 9-sep–7-dic; adjudicar cargo,
   devolución y una tx fuera de ventana. Editar únicamente notas y comprobar
   meta/fechas. Probar ventanas solo inicio, solo fin y rango invertido.
2. Editar importe/fecha de una tx adjudicada y borrarla/restaurarla; progreso
   debe actualizarse sin cerrar la pantalla. Error de lectura debe mostrar
   indisponibilidad y reintento, nunca avance cero. Reintento de adjudicación
   no debe crear otra transacción.
3. Capturar 2–3 fechas pasadas en una cuenta; reiniciar, cambiar de cuenta,
   cancelar y editar una tx antigua. Solo nuevas capturas exitosas cambian la
   sugerencia; una adjudicación fallida posterior al save debe conservarla.
4. Movimientos con filtro de cuenta, texto agrandado, ventanas estrecha/ancha y
   filas mezcladas con/sin badges. Verificar una línea, alineación, scroll y
   ausencia del hueco superior.
5. Renombrar Food & Drink y Groceries varias veces, reiniciar y comprobar que
   no reaparecen seeds. Renombrar Salary, Interest e Interest Charges; sueldo e
   intereses deben conservar los mismos totales. Cambiar color y comprobar
   badges sin reabrir vistas.
6. Exportar/restaurar fixtures manifest 11 con las dos estrategias; comprobar
   aliases, reglas, colores y adjudicaciones. Confirmar que los avisos de
   conflictos históricos llegan a Settings.

Release 0.17.0, instalación, recreación de promociones reales y seguimiento de
Aeromexico permanecen fuera del alcance autorizado.
