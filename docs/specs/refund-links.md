# Refund links (vincular reembolsos con compras)

Estado: READY FOR DEVELOPMENT VALIDATION (pendiente aprobación del usuario) · Especificación LOOPS §3 · Rama `feat/refund-links`

## Problema

El usuario compra frecuentemente con tarjeta de crédito y después recibe un
reembolso (p. ej. compras para terceros que se pagan de inmediato por
transferencia a la cuenta de débito). Hoy el reembolso cuenta como ingreso y la
compra como gasto completo, inflando ambos. Un reembolso vinculado **no es un
ingreso: es gasto menor**.

## Semántica financiera (decisiones aprobadas por el usuario)

- Un vínculo conecta **un reembolso** (movimiento positivo) con **una compra**
  (gasto regular). Una compra puede recibir **varios reembolsos parciales**
  cuyo acumulado no supera `abs(compra.amount)`; cada reembolso tiene un solo
  vínculo activo.
- **Atribución al mes de la compra**: el gasto neto
  (`abs(compra) − reembolsos aplicados`) se refleja en la fecha/categoría/cuenta
  de la compra. El mes del reembolso deja de contarlo como ingreso. Vincular
  recalcula meses anteriores.
- **Flujo de efectivo intacto** (base de efectivo): el reembolso sigue siendo
  entrada real de efectivo en su propia fecha/cuenta. **Patrimonio intacto**:
  los saldos ya reflejan ambas piernas.
- Elegibilidad compra: gasto regular no eliminado/no duplicado/no transferencia.
  Elegibilidad reembolso: positivo, misma moneda, `postedAt ≥ compra.postedAt`,
  no MSI sintetizado; en tarjeta `cardCredit`+`adjustment`, en cuenta de activo
  `income` + ingreso regular.

## Flujo de usuario (UX aprobada)

1. **Agregar movimiento** → Ingreso → categoría **Reembolso** → aparece fila
   opcional **"Vincular compra"** (mismos patrones de fila del formulario).
2. La fila abre un modal con: **orden** por fecha/concepto/monto (por defecto
   más reciente → más antiguo), **filtro por cuenta**, **búsqueda**. Solo
   compras elegibles. Tocar fila = seleccionar; **Aceptar** regresa al
   formulario; nada se guarda en el modal.
3. Al **Guardar**: se valida el borrador (margen pendiente, moneda, fecha) —
   si falla, error en el formulario y no se guarda nada; si pasa, se crea el
   movimiento y el vínculo.
4. En el **detalle** de movimientos existentes (p. ej. reembolsos importados):
   sección "Movimientos vinculados" con las mismas direcciones
   reembolso↔compra usando el mismo modal con Aceptar.

## Alcance excluido (no-goals)

- Vínculos genéricos "movimientos relacionados" (quitados del WIP original).
- Un reembolso repartido entre varias compras (importes por vínculo).
- Cambiar flujo de efectivo, patrimonio o liquidación del hogar.

## Persistencia y compatibilidad

- Sidecar `TransactionLink` (AD-023): sin relaciones, UUIDs, tombstone
  `deletedAt`, `identityKey = "refund:<refundID>"`, id determinista
  SHA-256. Migrazción ligera V7→V8 (`FinanceTrackerSchemaV8`).
- Backup manifest v15: exporta/restaura vínculos; backups v14 restauran sin
  vínculos; merge por `lastModifiedAt` con victoria del tombstone en empate.
- `AppDataResetService` borra vínculos antes de transacciones;
  `AccountDeletionService` también los limpia al borrar una cuenta.

## Criterios de aceptación

1. Flujo completo §"Flujo de usuario" reproducible en la Dev app.
2. Mes de la compra con gasto neto; mes del reembolso sin ese ingreso; flujo de
   efectivo y patrimonio sin cambios; desgloses muestran original/reembolsos/neto.
3. Backup v14 (respaldo real del usuario) restaura bajo V8; v15 hace round-trip;
   merge preserva desvínculos.
4. Suite serial completa en verde + evidencia de performance §8 LOOPS.

## Evidencia de verificación (2026-11-19)

- **Build**: `** BUILD SUCCEEDED **` (Debug, esquema FinanceTracker).
- **Suites enfocadas**: TransactionLinkTests 12/12; BackupArchiveTests,
  AppDataResetServiceTests, DashboardDataChangePolicyTests,
  AccountDeletionServiceTests — 63/63.
- **Respaldo real** (`FinanceTracker-2026-11-17T19-07-48-0600.ftbackup`, app
  0.18.3): `manifest_schema=14` → replaceAll bajo V8 en disco temporal:
  `accounts=20 transactions=1325 links=0` → re-export valida como v15.
- **Suite serial completa**: **811 tests, 811 en verde** (incluidos los dos
  que fallaban en `main` por deriva del entorno Xcode 6.4.2/macOS 27.2 y se
  atendieron en este mismo PR: congelamiento de `FinanceTrackerSchemaV5`
  siguiendo el patrón V6 — V5 referenciaba tipos vivos ya derivados y el
  almacén V5 del test no coincidía con ninguna etapa del plan de migración;
  y recalibración documentada de los umbrales del guardián de performance del
  dashboard: misma carga ≈1.95 s / conmutaciones ≈0.86 s bajo el compilador
  nuevo, costo lineal por movimiento sin O(n²)).
- **Performance §8** (test `refundFeaturePerformanceOnRepresentativeLedger`,
  800 movimientos / 400 vínculos): apertura del selector 50.8 ms, filtro de
  apertura 28.2 ms, búsqueda 2.6 ms, resumen de vínculos 71.7 ms, proyección
  58.1 ms, actualización solo-vínculo 93.2 ms, refresh de pasivo/activo
  76–84 ms — primeras interacciones dentro del presupuesto <100 ms.
  Refresco consolidado completo 145 ms (trabajo de fondo permitido).
- **Perfilado interactivo** (2026-11-19, Time Profiler 4 min, usuario
  conduciendo el flujo completo en la Dev app con datos reales creados en el
  contenedor dev): tabla `hang-risks` = **0 eventos** en toda la sesión
  (captura → fila «Vincular compra» → ordenar/filtrar/buscar → Aceptar →
  Guardar → detalle con gasto neto). Código del feature en la traza:
  TransactionLinkService 6 muestras·ms, picker 18, hoja de captura 90,
  linkRefund 3, validateRefundDraft 1 (~0.05 % del tiempo de la sesión).
  Verificación funcional en la misma sesión: vínculo persistido con identidad
  `refund:<uuid>` y 1 fila activa en el almacén dev. Plantilla Animation
  Hitches dedicada no grabada (los hang-risks del Time Profiler cubren los
  bloqueos de respuesta; limitación registrada).

## Rollback

Tras el primer arranque de esta build el almacén migra a V8 (0.11.0) y los
respaldos nuevos son v15; 0.18.3 no puede abrir V8 ni listar v15 (rechazo
limpio). **Rollback a 0.18.3 = reinstalar el .app anterior + restaurar el
último `.ftbackup` v14 pre-actualización vía replaceAll.** La verificación de
respaldo fresco pre-instalación (LOOPS §14) cubre ese requisito.
