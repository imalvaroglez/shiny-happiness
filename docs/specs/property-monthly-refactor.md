# Refactor mensual de Propiedades aprobado

Estado: IMPLEMENTING. Referencia visual aprobada: `propiedades-filas-unificadas.html` en los artefactos del chat.

## Contrato

Barra lateral: Resumen, Cuentas y Propiedades con un componente desplegable común; Movimientos, Importar estados y Configuración al final. Creación en Agregar, orden de cuentas en menú contextual. Sin contador de casas.

Dos pestañas por casa: Mes y Configuración. Una tabla mensual compartida con Integrante, Ingreso del mes, Estado, Por aportar y Acciones. Editar y finalizar participación dentro del renglón. Las referencias se guardan al abandonar el campo; Confirmar y Enter guardan el importe actual y su confirmación, incluyendo cero. Cualquier edición invalida la confirmación. No se permiten escrituras diferidas que sobreescriban una confirmación. “Por calcular” distingue falta de información de saldo nulo.

Los cierres conservan sus obligaciones. Cobros reales hasta la fecha de consulta, incluso tardíos, reducen su periodo aplicado. Anticipos, deuda anterior y crédito se muestran separados. Los repartos heredados del hogar se consideran históricos por conciliar; no se convierten automáticamente en deuda.

Sidecar v2 y respaldo v14: enlace de hogar, identidades estables y configuración mensual confirmable. Los meses editados usan exclusivamente el sidecar. Los registros SwiftData heredados permanecen de lectura. La lectura de v1 migra en memoria, sin escribir; las acciones explícitas publican v2 atómicamente. Mantener integridad, combinación, bajas lógicas, restauración y reinicio.

Formularios nativos con título visible, etiquetas completas, importes MXN y Cancelar/Guardar. Un error conserva borrador y ventana. Referencias de servicios son planeación opcional. Actividad muestra movimientos auténticos.

## Verificación requerida

Confirmaciones y reversión; ingresos cero; orden de guardados; vigencias; consultas a fecha; cobros parciales/anticipos; doble aplicación; equivalencia Household; cierres; v1/v2; corrupción; fallos; backup14; restauración y reset. Pruebas enfocadas, suite serial, Debug canónico, guardas monetarias, localización y whitespace. Revisiones independientes de persistencia, cálculos y UI.

Capturas, automatización de ventanas, teclado, VoiceOver, tamaños y apariencias permanecen pendientes de autorización de disponibilidad de pantalla. No declarar preparación para validación sin esas comprobaciones ni evidencia de respuesta visible menor a 100 ms. Sin versión ni instalación de producción.

## Continuación aprobada — tablas, actividad y asignación (25 de octubre de 2026)

El canon existente queda documentado en `docs/UI_GUIDELINES.md`. Las tablas usan
un layout común de encabezados/filas, anchura completa y variante compacta mediante
`ViewThatFits`, sin desplazamiento horizontal. Cobros, mantenimiento, referencias
y sus acciones comparten el margen de `PropertySectionHeading` y `PropertyTableCard`.

`PropertyActivityPresenter` identifica cada fila por movimiento, reúne aplicaciones
de un mismo cobro y muestra fecha, concepto, cuenta, tipo, responsabilidad e importe
sin signo visual. La fuente viva tiene prioridad; una fuente no disponible conserva
referencias capturadas y no inventa cuenta ni importe. La renta sigue fuera de la
actividad. El popover de cobro explica sus aplicaciones sin volver a sumar el origen.
`Vinculados` es el filtro inicial; `Por asignar` conserva la elegibilidad del destino.
Todas las columnas de datos de la actividad se ordenan ascendente o descendente;
en la tabla amplia se activa desde el encabezado y en la compacta desde un menú.
Al ordenar por otra columna, fecha ascendente desempata antes del UUID. Los registros
sin fecha, cuenta o importe quedan al final. Los filtros admiten varias cuentas y
responsabilidades; las opciones de una columna se combinan con OR, y cuenta con
responsabilidad se combinan con AND. El propio título de cada columna filtrable es
un único menú con orden y selección de valores. Los títulos completos se mantienen
en una línea; la vista compacta los apila si no caben. El encabezado sigue disponible
cuando el filtro no devuelve resultados.

`PropertyAssignmentService` centraliza responsabilidad de renta y Household. En renta
se conservan UUID de atribución, cobertura, notas, mantenimiento y snapshots al cambiar
solo responsabilidad. El guardado valida fuentes actuales con una consulta por lote,
además del registro JSON canónico, para impedir destinos contradictorios o falsos
conflictos por precisión ISO8601. No añade consultas por fila ni recalcula consultando.

Household conserva sus campos `Transaction` y validación `isSettlementEligible`.
Primero valida el lote en un contexto aislado, incluyendo importes personalizados;
después publica en un solo guardado sobre las identidades de la interfaz. Ante un
fallo restaura únicamente los campos propios y vencimientos afectados, sin rollback
global ni pérdida de borradores ajenos. Elegir Compartido otra vez conserva overrides.
Los cierres protegen las asignaciones y ofrecen ajustes en un periodo abierto.

Finalizar participación sustituye la regla anterior: `firstInactiveMonth` es el mayor
entre mes seleccionado y mes real; `activeThrough` es su mes anterior, inclusivo.
No hay prorrateo diario. La retirada está disponible directamente en ambas casas. Las
atribuciones individuales o de grupos con integrantes inactivos conservan importes,
señalan asignación pendiente y bloquean cierre. Los ingresos históricos permanecen.
Al abandonar una fila de ingreso, el borrador se guarda en su casa y mes capturados,
aunque la navegación haya avanzado, sin convertirlo en confirmación.

La UI de Propiedades utiliza claves inglesas en el catálogo es-MX, incluida ayuda,
estados y errores nuevos; `Prior debt` es la clave única de deuda anterior. No se
alteran nombres de personas, cuentas o conceptos del usuario. Sidecar v2 y respaldo 14
se conservan; `accountName` y elegibilidad son entradas de consulta, no nuevos campos
persistidos en Transaction ni una nueva migración.

### Verificación de esta continuación

Estado: verificación automatizada y revisión independiente en curso. La evidencia
anterior del espacio de propiedades no acredita esta continuación. Capturas, teclado,
VoiceOver, tamaños, apariencia y respuesta visible inferior a 100 ms siguen pendientes
de disponibilidad explícita de pantalla. No preparado para validación de desarrollo;
sin commits, versión ni instalación de producción.

### Evidencia final de código — 25 de octubre de 2026

Estado: **verificación automatizada aprobada; validación visual y latencia visible pendientes**.
No se declara preparación para validación de desarrollo mientras falten esas comprobaciones.

Comandos ejecutados:

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:FinanceTrackerTests/PropertyAssignmentTests -only-testing:FinanceTrackerTests/PropertyManagementTests -only-testing:FinanceTrackerTests/HouseholdSettlementReportTests -only-testing:FinanceTrackerTests/BackupArchiveTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -configuration Debug build
plutil -lint FinanceTracker/es-MX.lproj/Localizable.strings
git diff --check
```

- Selección enfocada final: **119 pruebas, 4 suites, sin fallos, 3.543 s**.
- Suite completa final: **653 pruebas, 74 suites, sin fallos, 12.815 s**, `TEST SUCCEEDED`.
- Build Debug canónico: `BUILD SUCCEEDED`, sin override de DerivedData.
- Catálogo válido, sin claves duplicadas ni literales estáticos de UI de Propiedades
  sin clave en la comprobación ejecutada. Guardia Decimal de Domain y whitespace correctos.
- Preparación de **1,000 filas** con fuentes sintéticas y cuentas de prueba: **17.22 ms**.
  Se sustituyeron búsquedas repetidas por índices de disponibilidad/vínculos. Es tiempo
  de presentación de valores en memoria, **no medición de respuesta visible**.
- Revisiones independientes de persistencia/cálculos e interfaz: tres hallazgos iniciales
  sobre elegibilidad Household, fuentes de renta atrasadas y precisión JSON; tres finales
  sobre validación del formulario de vínculo, normalización de Custom y layouts independientes.
  Todos corregidos, con regresiones automatizadas. La revisión de seguimiento verificó
  las tres correcciones finales y no identificó nuevas regresiones en esos fragmentos;
  no ejecutó pruebas ni validó UI nativa. La normalización real del setter se comprobó
  además en `customEqualityNormalizesLegacyOverride`.
- Una repetición intermedia de la suite salió inesperadamente al liberar el contenedor
  en memoria de una prueba nueva mientras su tarea mensual seguía activa. La prueba ahora
  espera `refreshPeriod()` antes del teardown; las selecciones y suite final pasan.
- Se comprobó la preservación de archivos preexistentes respecto a la copia inicial:
  ningún archivo ajeno al alcance cambió durante esta continuación; el proyecto Xcode
  se regeneró por los nuevos Swift. No se realizaron commits ni preparación de versión.
- Sin capturas ni automatización de ventanas. Pendientes: ventanas estrechas/amplias,
  claro/oscuro, teclado, VoiceOver y respuesta visible inferior a 100 ms en la app Dev.
  La aplicación y los datos de producción permanecieron fuera del trabajo.

Logs locales: `/private/tmp/property-continuation-focused.log`,
`/private/tmp/property-continuation-full.log`, `/private/tmp/property-continuation-build.log`.
Revisiones: `/private/tmp/property-continuation-review.md`,
`/private/tmp/property-continuation-final-review.md`,
`/private/tmp/property-continuation-followup-review.md`.

### Orden de columnas de actividad — 25 de octubre de 2026

Los seis campos de datos (fecha, concepto, cuenta, tipo, responsabilidad e importe)
se pueden ordenar en ambas direcciones. La variante ancha usa encabezados pulsables;
la compacta presenta un menú con columna y dirección. Al ordenar por otra columna,
fecha ascendente desempata antes del UUID. Los filtros multiselección de cuenta y
responsabilidad se abren directamente desde el título de la columna, usan OR dentro
de cada criterio y AND entre ambos. El build Debug canónico pasó; no se ejecutó la suite de pruebas.
La interacción nativa y su respuesta visible quedan pendientes de la validación de
pantalla ya descrita.

Log local: `/private/tmp/property-header-filters-build.log`.

### Acciones directas de integrante — 25 de octubre de 2026

Cada fila ofrece Renombrar y Quitar, con etiquetas visibles y sin menú intermedio.
Renombrar modifica únicamente el nombre, conserva las notas y no escribe al abrir
el editor. Quitar confirma el mes efectivo antes de finalizar la participación;
conserva la identidad, ingresos, cargos individuales, cobros y cierres. También está
disponible en Paseo de los Parques. Sus gastos compartidos se calculan con los roles
que sigan activos; las asignaciones individuales o personalizadas a quien sale se
conservan y requieren conciliación antes del cierre. Los meses cerrados conservan
los integrantes y el reparto capturados. Sin cambio de schema ni respaldo.

Verificación de código de esta ampliación:

- Selección enfocada: 90 pruebas, 3 suites, sin fallos.
- Suite final serial: 656 pruebas, 74 suites, sin fallos, 13.847 s.
- Build Debug canónico correcto; catálogo es-MX sin claves duplicadas, guardia monetaria
  y whitespace correctos.
- Pruebas nuevas: renombrado sin otras modificaciones, retiro y reapertura, fallo de
  guardado sin pérdida, roles activos/ingreso cero, cargos aplazados sin adelantar su
  cobro, asignaciones pendientes y resumen inmutable de cierre.
- La revisión independiente detectó dos casos (cargo aplazado omitido y exportación
  viva de un cierre). Ambos se corrigieron; la revisión de seguimiento no encontró
  nuevos defectos concretos en esas correcciones.

Logs: `/private/tmp/property-member-actions-focused.log`,
`/private/tmp/property-member-actions-full.log`, `/private/tmp/property-member-actions-build.log`.
Revisiones: `/private/tmp/property-member-actions-review.md`,
`/private/tmp/property-member-actions-followup.md`.

La comprobación visual, teclado, VoiceOver y latencia visible sigue pendiente de
disponibilidad de pantalla. No se declara preparación para validación de desarrollo.

### Porcentajes, desglose y superficies — 26 de octubre de 2026

Cada integrante muestra el porcentaje del reparto compartido del reporte, con marca
de estimación si hay ingresos sin confirmar. No representa el reparto de cargos
individuales. Un reparto no calculable no muestra 0%; un ingreso confirmado cero
sí puede corresponder a 0%. En cierres se utiliza el porcentaje congelado.

La gráfica de gastos por categoría utiliza una fila por movimiento financiero
vinculado. Incluye cargos reales del periodo (también los aplazados del hogar),
excluye renta calculada, cobros y reembolsos. Conserva monedas separadas, distingue
Sin categoría de Categoría no disponible, y no consulta por fila. Las categorías
son metadatos actuales de la fuente viva; no se inventa una categoría para fuentes
históricas ausentes ni se modifica el esquema persistido.

El pie de actividad cuenta y suma las filas visibles. Los filtros de columnas cambian
Total por Subtotal; se separan tipo de movimiento y moneda para no mezclar gastos con
cobros ni convertir monedas. Los importes ausentes se indican y no se tratan como cero.
La gráfica resume todos los gastos vinculados del periodo; los filtros de la tabla
afectan únicamente el subtotal de esa tabla.

Propiedades hereda el AppBackdrop global de Cuentas, con GlassCard en indicadores,
tablas y superficies auxiliares. Se retira el fondo blanco opaco. Esta decisión
sustituye el canon previo de tablas opacas y queda en AGENTS.md y UI_GUIDELINES.md.
Se conservan cálculos, signos contables, cierres, sidecar v2 y respaldo 14.

Verificación final de código de esta ampliación:

- `xcodegen generate` incorporó los dos nuevos archivos Swift.
- Pruebas enfocadas: 126 pruebas en 4 suites, sin fallos, 3.684 s.
- Suite completa serial: 660 pruebas en 74 suites, sin fallos, 12.798 s.
- Build Debug canónico: BUILD SUCCEEDED. Catálogo es-MX válido y sin claves
  duplicadas; guardia monetaria de Domain y whitespace correctos.
- Preparación de resumen y desglose de 1,000 filas: 3.629 ms. Es una medición de
  cálculo en memoria, no de dibujo ni de latencia visible.
- Revisión independiente: detectó que la nueva categoría de presentación podía
  provocar un falso conflicto en el guardado Household. Se comparte la comparación
  financiera entre rentas y Household, ignorando únicamente ID/nombre de categoría,
  y manteniendo elegibilidad, importe y destino. La regresión ejercita ambos guardados
  tras un renombrado de categoría. El seguimiento confirmó la corrección y no encontró
  defectos concretos nuevos en ese cambio.

Logs: `/private/tmp/property-report-details-focused.log`,
`/private/tmp/property-report-details-full.log`, `/private/tmp/property-report-details-build.log`.
Revisiones: `/private/tmp/property-report-details-review.md`,
`/private/tmp/property-report-details-followup.md`.

La comprobación nativa de apariencias, teclado, VoiceOver y latencia visible permanece
pendiente de disponibilidad de pantalla. No se declara preparación para validación de
desarrollo; sin commits, versión ni instalación de producción.


## Sankey de gastos — continuación 2026-10-26

Sustituir la dona de Propiedades por Gasto total → Categorías → Subcategorías,
conservando Liquid Glass. El gráfico recibe los gastos vinculados de todo el mes;
los filtros de movimientos únicamente afectan la tabla y su subtotal. No incluye
renta calculada, cobros ni reembolsos. Cada UUID financiero cuenta una vez y las
monedas permanecen separadas. Agregación y conexiones usan Decimal; únicamente
la proyección geométrica convierte proporciones a coordenadas.

Capturar durante la consulta existente la ruta raíz→categoría como valores sin
SwiftData. No guardar esta jerarquía en el sidecar ni cambiar respaldo 14; excluirla
de comparaciones financieras al guardar asignaciones. Sin categoría se distingue de
categoría histórica no disponible; asignación directa termina en Sin subcategoría.
Las jerarquías profundas muestran la raíz y la ruta restante.

El resumen conserva cinco categorías y agrupa las demás. Cada categoría muestra
hasta tres detalles: si hay más, dos principales y Otras subcategorías. Ver todas
elimina agrupaciones; Resumir las restaura, manteniendo totales y paleta. Los nodos
se ordenan por importe descendente con desempate por identidad. Las etiquetas
muestran nombre, importe y porcentaje del gasto total de su moneda.

Desde 720 puntos de contenido, curvas nativas proporcionales y etiquetas medidas
sin inflar barras monetarias. Por debajo, desglose jerárquico. Desplazamiento vertical
cuando el contenido exceda 520 puntos. Hover/foco permiten inspeccionar; clic/teclado
fijan el resaltado, Escape lo limpia. Ninguna interacción escribe movimientos ni
cambia los filtros. Mantener pruebas de conservación, duplicados, monedas,
agrupaciones, fuentes ausentes, jerarquía, conflictos de guardado y geometría.

Capturas, accesibilidad nativa y respuesta visible <100 ms siguen pendientes de
confirmación de disponibilidad de pantalla. Los tiempos de preparación de datos
son evidencia auxiliar, no equivalen a latencia visible. Sin release ni producción.


### Evidencia automatizada del Sankey

- `xcodegen generate`: incorporados `PropertyExpenseFlow.swift`,
  `PropertySankeyLayout.swift` y `PropertySankeyTests.swift`.
- Pruebas enfocadas iniciales: 130 pruebas en 5 suites, 3.847 s, sin fallos.
- Suite serial final: 666 pruebas en 75 suites, 13.484 s, sin fallos.
- Preparación de 1,000 gastos, 12 categorías y 120 detalles: resumen, expansión y
  geometría en 14.964 ms. Solo trabajo en memoria, no latencia visible.
- Revisión independiente inicial: hallazgo IMPORTANT de orden de nodos «Otros»
  tras agrupar. Se ordenan ahora los nodos agregados, conservando juntas las ramas;
  regresión explícita con agregado de 15 frente a detalles 10 y 9 y con categoría
  agregada de 40 frente a principal 34. Prueba y suite serial pasaron.
- Catálogo es-MX válido y sin claves duplicadas. Guardia monetaria Domain sin
  Double/Float. Whitespace comprobado incluyendo los archivos nuevos.
- Previews sintéticos amplios, compactos y expandidos, con nombres largos y varias
  categorías. No se realizaron capturas ni automatización de ventanas.

Logs: `/private/tmp/property-sankey-focused.log`,
`/private/tmp/property-sankey-full-final.log`, `/private/tmp/property-sankey-build-final.log`.
Revisión inicial: `/private/tmp/property-sankey-review.md`.
La validación nativa y la latencia visible permanecen pendientes, por lo que este
lote no se declara listo para validación de desarrollo. Sin commits ni instalación.


Cierre de revisión de código: build Debug canónico posterior a la corrección,
`BUILD SUCCEEDED`. El seguimiento independiente en
`/private/tmp/property-sankey-followup.md` confirmó resuelto el IMPORTANT de orden,
sin nuevos defectos concretos. Revisó las variantes amplia/compacta, las tres
previews, la geometría y las interacciones; contrastó el log de las 666 pruebas.
No sustituye las comprobaciones nativas pendientes ni autoriza release/instalación.


## Aportaciones al Sankey — 2026-10-26

Ampliación aprobada: Integrantes → Gasto total → Categorías → Subcategorías.
Los flujos de entrada representan el gasto total multiplicado por los porcentajes
mensuales que ya aparecen en la tabla, incluidos los congelados al cerrar. No son
pagos cobrados, salarios completos ni la responsabilidad individual de los cargos.
Se usan nombres configurados, porcentajes completos y Decimal; mayores residuos
a centavos con desempate por UUID conservan el total exacto de cada moneda. Las
etiquetas conservan el porcentaje original del reporte, sin recalcularlo desde el
importe redondeado. Un porcentaje cero mantiene visible al integrante.

Porcentajes ausentes/incompletos muestran Aportaciones por calcular sin inventar
flujos; referencias sin confirmar muestran (estimado). Una tolerancia Decimal de
1e-24 admite únicamente colas de división insignificantes en la suma de shares,
no porcentajes incompletos. Se mantienen agrupaciones y Ver todas/Resumir, filtros
independientes y colores de categorías. Las etapas explícitas conducen geometría
y resaltado; seleccionar un integrante solo resalta su entrada hacia Gasto total.

El layout conserva 720 puntos como mínimo del diagrama completo y hasta 520 puntos
de viewport vertical. La alternativa compacta comienza por integrantes y después
desglosa el total. Previews amplios, compactos y expandidos tienen aportaciones y
nombres sintéticos largos. No hay nuevas consultas, persistencia ni versiones.

Pruebas: proporciones 98.45%/1.55%, conservación en cuatro etapas, centavos y empates,
participación cero y única, referencias estimadas, datos insuficientes, monedas,
expansión, cierres congelados y selección. Capturas, accesibilidad nativa y latencia
visible siguen pendientes de disponibilidad de pantalla; no declarar readiness.


### Evidencia de aportaciones

- Pruebas enfocadas: 105 pruebas en 4 suites, 1.473 s, sin fallos.
- Suite completa serial: 671 pruebas en 75 suites, 13.189 s, sin fallos.
- Build Debug canónico: BUILD SUCCEEDED, sin abrir ventanas ni instalar.
- Preparación de resumen, expansión y geometría con aportaciones, 1,000 gastos,
  12 categorías y 120 detalles: 17.939 ms. Medición auxiliar en memoria; no incluye
  dibujo, inspección nativa ni respuesta visible.
- Catálogo es-MX válido y sin claves duplicadas, guardia monetaria Domain sin
  Double/Float y whitespace comprobado. No se añadieron archivos Swift.

Logs: `/private/tmp/property-contributions-focused-final.log`,
`/private/tmp/property-contributions-full.log`, `/private/tmp/property-contributions-build.log`.
Diff sobre el working tree inicial conservado: `/private/tmp/property-contributions.diff`.
Se mantienen pendientes disponibilidad de pantalla, pruebas nativas y latencia
visible. Sin declaración de preparación para validación de desarrollo ni cambios
en producción.


Revisión independiente: `/private/tmp/property-contributions-review.md`, sin
BLOCKING ni IMPORTANT y sin defectos funcionales concretos. Única observación
NON-BLOCKING: ampliar cobertura justo dentro/fuera de tolerancia 1e-24. Se añadieron
casos por debajo, en el límite y por encima de uno, verificando conservación y
porcentajes originales. Repetición enfocada: 11 pruebas Sankey en 0.038 s, sin fallos
(`/private/tmp/property-contributions-tolerance.log`). Solo se ampliaron pruebas;
el código de aplicación corresponde al build y suite completa registrados arriba.
