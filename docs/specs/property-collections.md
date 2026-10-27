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
El historial agrupa por ingreso, muestra importe original y aplicado, y abre el
detalle de las aplicaciones y el movimiento. Los repartos históricos no
cerrados de Household no se convierten automáticamente en deuda.

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
