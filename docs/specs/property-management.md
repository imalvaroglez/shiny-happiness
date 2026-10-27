# Administración de propiedades

## Alcance

FinanceTracker administra propiedades y residentes en una capa de reportes que
usa movimientos financieros existentes. El ledger de propiedades no altera las
sumas personales ni el registro de transacciones. Paseo de los Parques, el hogar
con Fer, y Villas de la Hacienda viven bajo una sola opción de navegación. El
hogar conserva su calculadora y configuración actuales; el resumen consolidado
suma sus gastos del mes con los gastos reales atribuidos a las otras casas.

## Persistencia

- `PropertyLedger.json` es un sidecar JSON versión 1 bajo
  `Application Support/FinanceTracker/`; las pruebas usan el directorio temporal
  de pruebas y las APIs aceptan rutas inyectables.
- Las escrituras son atómicas. Una lectura corrupta o una escritura fallida se
  informa y no se sustituye el ledger por uno vacío.
- Las entidades llevan UUID; los registros editables usan marcas de tiempo y
  bajas lógicas para permitir merges. Un cierre es una copia indivisible de
  ingresos, residentes, obligaciones y distribuciones. Dos cierres distintos
  del mismo periodo se conservan en el destino y generan una advertencia para
  conciliación explícita.
- `.ftbackup` schema 13 incluye el ledger, conteo e integridad SHA-256. En
  `replaceAll`, un respaldo sin ledger lo limpia; en `mergeKeepingNewer` lo deja
  intacto. El reinicio total limpia el ledger. No cambia el esquema SwiftData.

## Reglas económicas

- Meses con calendario local. La renta de $1,300 sigue vigente hasta octubre de
  2026; $3,000 aplica desde noviembre de 2026. Un cambio afecta únicamente los
  periodos abiertos que correspondan.
- El ingreso de referencia es estimado. Cada residente activo debe confirmar
  su ingreso mensual para cerrar, y cero es un valor válido. Sin ingreso
  combinado positivo, las obligaciones compartidas quedan pendientes.
- El reparto usa `Decimal`, asigna primero pesos completos y después los
  centavos existentes, distribuye residuos por mayor residuo y desempata por
  UUID. Un gasto individual se asigna completo a la persona elegida.
- Solo un movimiento real atribuido produce un gasto. Cobros requieren un
  movimiento positivo de una cuenta de cheques, ahorro o efectivo; se pueden
  aplicar en partes, y el saldo disponible del movimiento no se excede. La
  sugerencia propone primero el adeudo más antiguo y, dentro del periodo, renta
  antes que gastos. El importe no aplicado puede guardarse como anticipo ligado
  al movimiento y luego convertirse en aplicaciones; aplicaciones más anticipo
  nunca pueden exceder el cobro original.
- Los reembolsos recibidos se atribuyen como ingresos reales de la propiedad.
  Mejoran el resultado operativo sin reducir las obligaciones de residentes ni
  poder aplicarse también como cobro de renta.
- Una atribución guarda la fecha de contabilización del movimiento como
  periodo de gasto. El periodo de cobertura de un recibo se conserva como dato
  informativo y no prorratea el gasto.
- Los cierres conservan la distribución original. La cobranza se actualiza por
  separado; movimientos originales o cobros modificados se señalan como
  discrepancias para corregirlas con un ajuste justificado en un periodo abierto.
- El programa de mantenimiento inicial abarca noviembre de 2026 a octubre de
  2027, con presupuesto de $24,000 y recuperación máxima de $2,000 por mes de
  renta. Solo inversión real atribuida al propietario y renta efectivamente
  cobrada generan importes. Cobros tardíos conservan el límite del mes de renta.
  La reserva futura es un movimiento manual interno, no un ingreso o egreso
  financiero.
- El resultado operativo usa cobros aplicados en el mes y gastos operativos
  reales; el resultado posterior descuenta además el mantenimiento real. Las
  obligaciones pendientes y la recuperación de capital se muestran aparte.

## Experiencia

El diseño de la ventana y la navegación compartida se detallan en
[property-workspace-ui.md](property-workspace-ui.md).

La navegación ofrece una sola opción, **Propiedades**, con Paseo de los Parques,
una vista consolidada y el detalle mensual de cada otra propiedad, incluida
Villas de la Hacienda cuando se configure. El resumen
acumula gastos incluidos del hogar y gastos reales atribuidos a las demás casas;
la cobranza a Fer queda visible por separado. La casa del hogar conserva sus
miembros y reglas actuales. Cada otra propiedad configura residentes, acuerdos
históricos de renta, referencias de servicios, atribuciones, pagos, ajustes,
programa de mantenimiento y reserva. Las capturas indican el destino del
movimiento; cada movimiento participa en el reporte de hogar o en una propiedad
para no contar dos veces el mismo importe. Los ingresos de propiedad distinguen
cobros de residentes de reembolsos recibidos.

Las propiedades y residentes se configuran de forma revisable; no se insertan
propiedades de demostración ni datos familiares automáticamente. No se incluyen
ingresos ni documentos personales en fixtures del repositorio.

## Verificación

`PropertyManagementTests` cubre reparto con pesos y centavos, ingresos cero,
vigencia de residentes, renta y servicios reales, gasto individual, cierres,
cobros parciales y tardíos, presupuesto y recuperación, reserva, merges y
archivos corruptos. `BackupArchiveTests.propertyLedgerBackupRoundTrip` cubre
schema 13 y el comportamiento de reemplazo y combinación de respaldos
anteriores.

La prueba representativa de 1,000 gastos atribuidos y tres residentes midió
21.44 ms en el cálculo puro del reporte, dentro del objetivo de 100 ms. Esa
medición no incluye las interacciones de lectura, edición, conciliación y cierre
ni los fotogramas de SwiftUI; el perfilado interactivo con Instruments queda
pendiente y no se infiere a partir de esta prueba.
