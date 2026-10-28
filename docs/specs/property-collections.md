# Cobros desde Propiedades — contrato de desarrollo

## Captura y cuentas

Desde cualquiera de las dos casas, **Registrar cobro** pide Cuenta, Integrante,
Importe y Fecha. La fecha inicial es hoy. El selector enumera todas las cuentas;
pueden elegirse las activas en MXN de cualquier tipo. Las cuentas cerradas,
archivadas o en otra moneda se muestran inhabilitadas con su motivo. El importe
sugerido suma el pendiente del mes seleccionado y la deuda
de meses cerrados anteriores, y resta anticipos del integrante. Se puede capturar
un importe parcial o mayor. La descripción identifica al integrante y la casa.
La sugerencia se presenta a dos decimales y la captura acepta hasta dos
decimales, sin redondeos al guardar que el usuario no haya visto. El reporte
conserva sus importes `Decimal` originales.

La captura llama a `ManualTransactionService` para crear un ingreso real. Luego
guarda las aplicaciones en el sidecar de Propiedades. El movimiento de SwiftData
se guarda **primero**; si el segundo guardado falla, el ingreso queda en la cuenta
y la ventana conserva su UUID para reintentar sin crear otro. Tras reabrir,
**Conciliar cobro existente** permite recuperar ingresos no vinculados. Los
ingresos existentes parcialmente aplicados, y los que aún conservan un anticipo,
también aparecen allí. Un origen no puede aplicarse a casas o integrantes
distintos silenciosamente.
Si un ingreso ya vinculado cambió de importe, fecha, moneda o descripción,
se detiene la nueva conciliación hasta revisar sus aplicaciones.

## Aplicación y saldos

Se paga la deuda más antigua primero. Dentro de cada mes, la renta precede a
otros conceptos. Los pagos de importe inferior al saldo son válidos. El excedente
se registra como anticipo ligado al integrante y al mismo movimiento financiero;
los anticipos anteriores sin integrante conservan una fila propia. Un cobro no
se aplica a obligaciones cuyo mes sea posterior a la fecha del ingreso. Cuando
el mes llega, el anticipo puede conciliarse contra esas obligaciones conservando
el UUID financiero original. Los cierres conservan obligaciones y repartos;
los cobros tardíos solo actualizan la cobranza.

La tabla mensual muestra deuda anterior y anticipo al lado de «Por aportar».
La columna Pago muestra el estado acumulado y abre el historial del integrante;
Cobrar y Aplicar anticipo son acciones directas de la fila. El historial agrupa
por ingreso, muestra importe original y aplicado, y abre el movimiento. Los cobros
se excluyen de las filas y subtotales de movimientos vinculados. Los repartos históricos no
cerrados de Household no se convierten automáticamente en deuda.

La captura seleccionada desde una fila precarga al integrante y su saldo calculable.
El importe se presenta a dos decimales y solo se edita al elegir Cambiar. Un saldo
desconocido queda por calcular; cero real permite registrar un anticipo.
El ingreso mensual se consulta como valor y se edita a petición; al confirmar se
guardan el importe y su confirmación. Los errores conservan el borrador.

## Persistencia, compatibilidad y límites

Se conservan el esquema de `Transaction`, sidecar v2 y respaldo 14. Los
anticipos nuevos usan el `residentID` real; los antiguos con identificador
placeholder siguen siendo válidos y visibles. Las pruebas usan cuentas y
propiedades sintéticas. No se abre la aplicación ni se usan datos de producción.

La verificación interactiva de ventanas, teclado, VoiceOver y latencia visible
queda pendiente hasta la autorización explícita de disponibilidad de pantalla.

## Evidencia automatizada y puertas pendientes

- `xcodegen generate` incorporó el calculador, formulario y pruebas nuevos.
- Pruebas enfocadas de cobros: 8 pruebas, 1 suite, sin fallos. Incluyen
  renta antes que servicios, pagos parciales, centavos, anticipo de integrante,
  anticipo heredado, fuente modificada, sugerencia a la fecha, ejemplo de Fer
  y reintento con un contexto de SwiftData nuevo tras fallo del sidecar.
- Suite serial completa: 679 pruebas, 76 suites, sin fallos; `TEST SUCCEEDED`.
  Build Debug canónico: `BUILD SUCCEEDED`.
- Catálogo es-MX válido, sin claves duplicadas; `git diff --check` limpio;
  sin `Double` ni `Float` en Domain.
- La revisión independiente de solo lectura se intentó con el diff acotado,
  pero el proceso Codex alcanzó el límite de uso antes de emitir hallazgos.
  La revisión sigue pendiente.
- Sin capturas ni automatización nativa por la restricción de pantalla. No hay
  evidencia de respuesta visible inferior a 100 ms, apariencia, teclado o
  VoiceOver. Este lote aún no se declara listo para validación de desarrollo.

Logs: `/private/tmp/property-collection-reopen-focus.log`,
`/private/tmp/property-collection-full-679.log`,
`/private/tmp/property-collection-debug-final.log` y
`/private/tmp/property-collection-independent-review.log`.

### Ajuste de cuentas e importe sugerido (26 de octubre de 2026)

- El selector presenta todas las cuentas. Cualquier cuenta activa en MXN puede
  recibir el ingreso; las cerradas, archivadas y de otra moneda aparecen con
  motivo y no pueden seleccionarse. La validación de la aplicación exige una
  fuente real, incluso cuando su cuenta no es de efectivo.
- El importe propuesto se redondea a centavos y se muestra siempre con dos
  decimales. La cifra del reporte no se modifica. La captura valida el texto
  completo, incluido el agrupamiento de millares. Los anticipos con fuentes
  modificadas no se ofrecen como disponibles ni se aplican a cobros posteriores;
  se exige revisar su origen antes de registrar otro cobro. Al guardar se releen
  en una consulta los movimientos de anticipos existentes para detectar cambios
  realizados desde otra ventana después de cargar el mes.
- Pruebas enfocadas: 12 pruebas, 1 suite, sin fallos. Incluyen registro en
  tarjeta, recuperación de mantenimiento desde ese cobro, elegibilidad de
  cuentas, formato de la sugerencia, importes mal formados y anticipos con
  fuentes modificadas, incluso desde otro contexto después de cargar el mes.
- Suite serial completa: 683 pruebas, 76 suites, sin fallos. Build Debug
  canónico: `BUILD SUCCEEDED`. Catálogo es-MX válido, sin claves duplicadas;
  `git diff --check` limpio y sin `Double` ni `Float` en Domain.
- La revisión independiente detectó dos fallos de validación; la segunda
  revisión identificó además una carrera de caché entre ventanas. Se corrigieron
  y la revisión final confirmó su resolución sin hallazgos pendientes en ese
  alcance. No se hicieron capturas ni
  automatización nativa. La validación visual, accesible y de latencia visible
  sigue pendiente.

Logs: `/private/tmp/property-accounts-rounding-focus-final.log`,
`/private/tmp/property-accounts-rounding-full.log` y
`/private/tmp/property-accounts-rounding-debug.log`; revisiones en
`/private/tmp/property-accounts-rounding-review.log` y
`/private/tmp/property-accounts-rounding-rereview.log` y
`/private/tmp/property-accounts-rounding-final-review.log`.

### Cuenta del integrante, pagos desbloqueados y recuperación por UUID (27 de octubre de 2026)

- **Cuenta del integrante.** La hoja «Integrante — Cuenta al fecha» reproduce la tabla
  exacta: Gastos compartidos de la casa (con Ver detalle), Parte del integrante,
  Gastos suyos (con Ver detalle), Renta, Deuda anterior (neta de cobros anteriores),
  Ajustes, Pagos aplicados (−) y Saldo pendiente. Renta, deuda anterior y ajustes solo
  aparecen cuando existen. Con un anticipo válido se añaden Anticipo disponible (−) e
  Importe sugerido a pagar = max(0, saldo pendiente − anticipo disponible); la
  sugerencia nunca es negativa: un anticipo mayor sugiere 0 y conserva su resto.
- **Suma a mano y notas factuales.** Saldo pendiente = deuda anterior + max(0, renta +
  parte + gastos suyos + ajustes − pagos aplicados del mes). El dinero que cubrió
  meses cerrados ya viaja neto dentro de la deuda anterior; sumarlo otra vez
  duplicaría. El saldo es numérico también en revisión — los registros sin respaldo no
  se descuentan en silencio, se exhiben aparte — y solo es nil en Por calcular,
  Por conciliar y Proyección: un mes futuro nunca se presenta como deuda. Las notas de
  revisión son factuales y separadas, con importe y motivo: un cobro sin descontar
  porque su movimiento no se encontró o cambió tras el registro; un anticipo que perdió
  su respaldo y no es dinero disponible (ofrece Abrir movimiento); y un cobro
  sobreaplicado nombrado con su movimiento.
- **Pagos nuevos independientes de incidencias antiguas.** Una referencia sin respaldo
  jamás bloquea registrar un pago nuevo, jamás es anticipo disponible ni salda
  obligaciones, y jamás ocupa capacidad. La regla de validez es compartida — existencia
  de la fuente, fecha, tipo de recibo, snapshot sin cambios, no sobreasignación y no
  doble uso (`isValidAppliedCollection` sobre el contexto `AppliedValidity`) — y la
  aplican por igual el saldo, la capacidad del walk y los cierres, de modo que las tres
  cifras nunca discrepan. Aplicar un anticipo explícito sigue exigiendo fuentes sanas.
- **Recuperación garantizada por UUID.** `pendingLinks` es durable en el sidecar:
  campo aditivo con decodificación tolerante de archivos viejos
  (`decodeIfPresent ?? []`), validación al cargar y fusión newest-wins. El marcador se
  escribe inmediatamente después de crear el ingreso, antes de cualquier escritura de
  Propiedades; se elimina al completar el vínculo, y los reintentos reutilizan el mismo
  marcador en lugar de duplicarlo. Sobrevive cierre y reapertura; renombrar al
  integrante o a la casa, o editar la descripción, no lo afecta porque fija el ingreso
  por UUID. El aviso contextual («Un ingreso de cobro espera ser vinculado a esta
  casa» → Vincular ahora) solo aparece con cobros pendientes identificados. Ventana
  residual documentada: una muerte del proceso entre el ingreso real y el marcador
  deja el ingreso sin marcador; se recupera manualmente con Conciliar cobro existente.
- **Clasificación real del adapter.** Las filas solo de Fer son individuales de Fer,
  las solo del usuario son individuales del usuario, y las compartidas — fusiones
  custom incluidas — son compartidas. Los totales y cierres quedan intactos.
  Limitación: los meses de hogar ya cerrados conservan la clasificación vieja, y su
  desglose y filtros son autoconsistentes con ella (cero consistente).
- **Ver detalle por identidad.** Los alcances filtran la tabla de actividad por
  identidad de atribución — compartido o `individual(id)` —, no por etiquetas: cubren
  meses cerrados, que renderizan el reparto concatenado, y grupos `.selected`, que
  renderizan nombres pero siguen siendo compartidos. Invariante desglose ↔ filtro ↔
  subtotal: el subtotal de las filas del alcance reproduce la cifra de la hoja. Nota de
  borde conocida y aceptada provisionalmente: las filas de Fer con vencimiento
  diferido reciben identidad individual aunque estén fuera de los `individualCharges`
  del mes; queda a revisión (§9 de LOOPS).
- **Evidencia de esta ronda** (3491065…e5f242a sobre c509ab5):
  - Build Debug canónico: `BUILD SUCCEEDED`.
  - Suite enfocada `Property collection posting`: 49 pruebas, 1 suite, sin fallos
    (`TEST SUCCEEDED`); cubre la cuenta que suma a mano, la regla compartida de
    validez, los marcadores `pendingLinks` (reapertura, renombres, limpieza al
    completar, decodificación tolerante y fusión) y la clasificación del adapter.
  - Suite enfocada `Property management`: 23 pruebas, 1 suite, sin fallos
    (`TEST SUCCEEDED`); incluye los alcances por identidad y el invariante con los
    subtotales.
  - Corrección del conteo enfocado (FIX-§9, 27 de octubre): la doble revisión
    cuestionó la suma enfocada (afirmó 73). El recuento verificado en `6481f5d`
    confirma 49 + 23 = 72 pruebas (tres corridas seriales `TEST SUCCEEDED`, más
    `focus-posting.log` y `focus-management.log` de la propia ronda, que reportan
    49 y 23); la afirmación de 73 no se reproduce, y el conteo registrado queda
    en 72.
  - Suite serial completa: 736 pruebas, 77 suites, con exactamente los 2 fallos
    preexistentes diferidos por decisión del dueño — «Dashboard refresh stays
    responsive with larger imported history» (umbral de 0.75 s) y «V5 on-disk store
    migrates to V6 and supports a due-date override» (`unknownDataStoreSchema`) —;
    ningún otro fallo.
  - Bisect de la migración: en la base exacta `d417ad9` ese mismo test ya falla con la
    misma firma (RC 65, `unknownDataStoreSchema` en HouseholdSettlementReportTests.swift:898,
    1 prueba en 1 suite), de modo que el fallo es preexistente del WIP base
    (28e0b42/d417ad9) y no de este lote.
  - `plutil -lint` OK y sin claves duplicadas en el catálogo es-MX;
    `git diff --check` limpio; sin `Double` ni `Float` en Domain.

  Logs: `/tmp/ft-tg-logs/focus-posting.log`, `/tmp/ft-tg-logs/focus-management.log`,
  `/tmp/ft-tg-logs/full-suite.log`, `/tmp/ft-tg-logs/bisect-d417ad9.log` y
  `/tmp/ft-tg-logs/debug-build.log`.

### Precisión de segundos, cuentas disponibles y Sankey con presupuesto (28 de octubre de 2026)

- **Comparación de snapshots a segundos enteros.** El respaldo local conserva
  fechas ISO 8601 sin fracciones; SwiftData conserva sub-segundos. La
  comparación exacta interpretaba esa pérdida como modificación y provocaba un
  estado «Revisar» falso tras registrar pagos (caso real de $247.65). Ahora
  `isSameWholeSecond` (piso de segundos en ambos lados) gobierna `hasSourceChanged`,
  el reporte congelado y la fila de actividad; una edición real confinada al
  mismo segundo no se señala, por coincidir con la precisión del formato en
  disco. Importe, moneda y descripción siguen comparándose exactos, y un cambio
  real a otro segundo se detecta.
- **Avisos que identifican.** Los avisos de revisión nombran los campos
  cambiados («…cambió (fecha, importe) desde que se concilió…») y cada cobro
  afectado expone su movimiento desde la cuenta del integrante; ninguna lista
  de campos queda sin movimiento asociado.
- **Cuentas disponibles.** Activa significa no archivada y no cerrada
  (`Account.isAvailableForCapture`). Los servicios de creación —movimientos,
  transferencias (ambas partes antes de insertar) y cobros— re-fetchean la
  cuenta por UUID en un contexto nuevo del mismo contenedor
  (`AccountCaptureValidation.ensureAvailable`) y rechazan antes de insertar
  nada; los selectores excluyen archivadas y cerradas, y si la selección muere
  en caliente se conserva integrante, importe y fecha.
- **Interfaz.** La cuenta del integrante pierde el subtítulo de casa y mes (la
  proyección solo se indica cuando aplica), adopta una tabla de tres columnas
  con anchos compartidos por fila y altura al contenido con desplazamiento
  solo si excede. El ingreso del mes se edita tocando la propia cifra (aspecto
  de texto normal, activable con teclado; Enter confirma, Escape cancela, salir
  del campo guarda como referencia sin confirmar). «Movimientos vinculados»
  comparte fila con el selector de alcance —en ventanas estrechas el selector
  cae a una segunda fila alineada a la derecha— y las acciones de selección
  ocupan fila propia.
- **Sankey con presupuesto.** El resumen muestra, por moneda, el prefijo de
  categorías cuya suma acumulada no supera el 80 % del gasto (límite en
  `Decimal` exacto, empates resueltos por identificador, sin saltar categorías
  grandes para incluir pequeñas). La primera categoría que excedería el límite
  se agrupa con todas las siguientes en «Otras categorías», colocada al final
  con el restante real — que puede superar el 20 % —; si la primera supera el
  80 % por sí sola, se muestra y se agrupa el resto. La expansión se ofrece
  solo cuando el desglose cambia, y el total, las aportaciones y las
  conexiones son idénticos entre ambas presentaciones.
- **Evidencia.** Suite serial completa: 765 pruebas, 77 suites, exactamente
  los 2 fallos preexistentes diferidos (latencia del Dashboard, 0.8475 s
  frente a < 0.75 s con la máquina compartida; migración V5→V6 probada
  preexistente por bisect en `d417ad9`). Build Debug canónico en verde; sin
  `Double` ni `Float` en Domain; catálogo es-MX válido y sin duplicados;
  `git diff --check` limpio. Verificación visual, teclado, VoiceOver y
  latencia visible pendientes de disponibilidad de pantalla: este binario es
  para prueba, no «listo para validación».

### Marcador-primero, identidad congelada y una sola regla de validez (28 de octubre de 2026, ronda 4)

Correcciones de la cuarta ronda de revisión (`87559fd`…`f2aac51` sobre el
lote anterior; el binario de prueba lleva el sello `afc8700`).

- **El retiro de marcadores sobrevive a errores de lectura.** Antes,
  `retirePendingLinks` trataba un fetch fallido de los pagos guardados como
  «todos los movimientos desaparecieron»: el `try?` convertía el error en un
  diccionario vacío, se retiraban todos los marcadores y se guardaba el
  registro — destruyendo en disco el estado de recuperación de ingresos que
  seguían vivos. Ahora el fetch corre en `do/catch`: con error no se retira
  ni se guarda nada, los marcadores se conservan para que la siguiente tarea
  reintente, y el usuario ve el motivo («no se pudieron consultar los pagos
  guardados; se conservaron los marcadores de recuperación»). El retiro
  (ausente o borrado suave) solo ocurre tras una consulta exitosa. La lectura
  pura del aviso, `pendingLinks(propertyID:)`, no cambia. Las pruebas inyectan
  el fallo por la costura `pendingLinkFetchOverride`, espejo de
  `revisionCheckOverride`.
- **El marcador se escribe antes que el ingreso.** `registerCollection`
  creaba el ingreso y fijaba el marcador después: un fallo intermedio
  publicaba dinero que el registro de Propiedades jamás podría señalar. La
  rama de creación ahora es marcador-primero: valida cuenta/MXN y la revisión
  de asignaciones, fija durable un UUID de pago nuevo
  (`upsertPendingMarker`, escritura pura de estado de flujo, sin filas
  financieras) y luego crea el ingreso con exactamente ese UUID —
  `ManualTransactionService.create` acepta un `id` opcional y, si su guardado
  falla, elimina el insert antes de relanzar, de modo que ningún save o
  autosave posterior puede publicarlo. Tabla de resultados:
  - fallo del marcador → rechazo limpio, sin ingreso creado;
  - fallo al guardar el ingreso → rechazo limpio, sin ingreso publicable; el
    marcador huérfano se retira solo en la siguiente tarea cuando una
    consulta exitosa no encuentra fila;
  - ingreso ya existe y falla la escritura de aplicaciones → recuperación
    durable `needsLink` por UUID; el reintento reutiliza el mismo recibo,
    nunca un segundo ingreso.
  La ventana residual documentada el 27 de octubre (muerte del proceso entre
  ingreso y marcador) queda cerrada por inversión: ahora el marcador precede
  al dinero y el huérfano posible es el marcador, no el ingreso.
- **La identidad congelada del cierre manda en meses cerrados.** El desglose
  de un mes cerrado se calcula desde el snapshot congelado del cierre, así
  que una fila cerrada con obligación en ese snapshot toma su identidad de la
  responsabilidad congelada — compartida y `.selected` → compartida,
  `individual(miembro)` → individual, propietario → fuera de los alcances —
  antes de consultar la asignación actual del hogar. Antes, el mapa vigente
  (p. ej. `.partner`) podía re-alcancear una fila que el cierre clasificó
  compartida, haciendo que un alcance de integrante sumara filas que el
  desglose congelado cuenta como cero: el cero contradictorio.
- **La entrada manual de importe nunca queda oculta por revisión.** El botón
  «Capturar importe» permanece visible también cuando el estado de la
  sugerencia es revisión: la nota explica por qué la sugerencia no es de
  confiar, pero jamás bloquea registrar el pago. Esa combinación (ingresos
  sin confirmar + referencia inválida → importe desconocido + revisión) antes
  dejaba el flujo sin forma de guardar.
- **Los ajustes de valuación rechazan cuentas no disponibles.**
  `BalanceSnapshotService.createAdjustment` escribía un snapshot
  `manualAdjustment` y su movimiento espejo sobre cualquier cuenta recibida,
  sin verificar disponibilidad: una valuación podía re-expresar el saldo de
  una cuenta que otra ventana ya había archivado o cerrado. Ahora corre
  primero la misma barrera de estado fresco que los movimientos manuales —
  `AccountCaptureValidation.ensureAvailable` re-lee la cuenta desde un
  `ModelContext` nuevo, de modo que tanto el objeto rancio como la cuenta
  persistida-no-disponible se rechazan con cero inserciones, sin snapshot ni
  movimiento espejo, antes de que la hoja construya nada.
- **Una sola regla de anticipo gastable, de extremo a extremo.** El walk de
  pagos aplica la regla de validez compartida sin huecos:
  - `isSpendableAdvance` es LA regla que aplican por igual las cuatro rutas
    — el filtro de `plan`, el walk de `applyAdvances`, la disponibilidad que
    publica el cierre del integrante y `memberAdvances` —: la fuente existe,
    sus snapshots no cambiaron, no está sobre-aplicada, no está
    sobreasignada, no se usó como reembolso y cobro a la vez, y sigue siendo
    recibo válido a la fecha. Un anticipo roto nunca bloquea un cobro nuevo:
    solo deja de ser dinero gastable.
  - `memberAdvances` recibe ahora `obligations` obligatorio — el alcance de
    conciliación del llamador — y `reconciliationObligations(report:ledger:)`
    lo define una vez: obligaciones del reporte más todos los cierres de la
    propiedad. Un recibo usado como reembolso en un mes ya cerrado es dinero
    doble-usado en todas las rutas por igual — la precalculación del cierre,
    los walks y `memberAdvances` alimentan el mismo conjunto a
    `reconciliationReview`, de modo que sus banderas de doble uso jamás
    discrepan.
  - El pendiente neto estricto del mes en `plan()` y `applyAdvances()` es
    `currentMonthOutstanding` = max(0, componentes − pagosVálidos −
    contribución directa), donde componentes es la porción del mes del
    integrante (renta + compartidos + gastos suyos + ajustes), los pagos
    válidos son sus aplicaciones no-anticipo contra las obligaciones del
    reporte bajo `validity.includes`, y la contribución directa — dinero
    pagado al registrar el gasto — cuenta exactamente una vez. Nunca el
    `balance` del reporte, cuyo filtro más laxo aún cuenta cobros cuya fuente
    cambió después y haría que el walk volviera a pedir dinero que el cierre
    ya reintegró. Es la misma cifra que el cierre del integrante publica como
    `max(0, monthBalance)`.

**Evidencia de esta ronda** (`87559fd`…`f2aac51` sobre el lote del 28 de
octubre por la mañana; binario de prueba sellado en `afc8700`):

- Suites enfocadas re-corridas en serie, todas `TEST SUCCEEDED` sin fallos:
  «Property collection posting» 68 pruebas en 1 suite (0.246 s);
  «Property management» 25 pruebas en 1 suite (0.056 s); «Manual Ledger»
  32 pruebas en 1 suite (0.345 s); «Property Sankey» 19 pruebas (0.040 s) más
  «Property assignment continuation» 25 pruebas (0.202 s) = 44. Los conteos
  coinciden con el recuento estático de `@Test` por archivo y con los del
  reporte de la ronda.
- Suite serial completa: 775 pruebas, 77 suites, exactamente los 2 fallos
  preexistentes diferidos por decisión del dueño — «Dashboard refresh stays
  responsive with larger imported history» (`periodSwitchElapsed` =
  0.8982150554656982 s frente al umbral < 0.75 s; el test corrió 5.942 s) y
  «V5 on-disk store migrates to V6 and supports a due-date override»
  (`unknownDataStoreSchema` en HouseholdSettlementReportTests.swift:898,
  probada preexistente por bisect en `d417ad9` el 27 de octubre). La porción
  de pruebas duró 13.461 s; ningún otro fallo.
- Build Debug canónico: `BUILD SUCCEEDED`. `plutil -lint` OK sobre el
  catálogo es-MX, 873 claves y 0 duplicadas; `git diff --check` limpio; sin
  `Double` ni `Float` en Domain. El commit de esta ronda toca solo
  documentación: sin `.swift` nuevos ni `xcodegen`.
- Verificación visual, teclado, VoiceOver y latencia visible siguen
  pendientes de disponibilidad de pantalla; este binario es para prueba, no
  «listo para validación».

Logs: `/tmp/f6-r4/full-suite.log`, `focus-posting.log`,
`focus-management.log`, `focus-manualledger.log`, `focus-sankey.log`,
`focus-assignment.log` y `debug-build.log`.
