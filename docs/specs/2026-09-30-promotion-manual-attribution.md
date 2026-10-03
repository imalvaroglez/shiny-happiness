# Promociones por adjudicación manual

**Status:** approved (2026-09-30). Producto del brainstorm del dueño + revisión
técnica de la misma fecha. **Suplanta la decisión AD-024 y el enfoque del
brainstorm 2026-09-22** (`docs/specs/2026-09-22-promotion-tracking-brainstorm.md`,
hoy superseded): el evaluador automático no convenció — «cualquier transacción
puede contar sin importar si aplica y esa lógica no es buena». Release objetivo:
0.17.0.

## Contrato de producto

El dueño crea promociones y decide, transacción por transacción, cuáles cuentan.
La app informa; jamás deduce elegibilidad.

- **PA-01 Reemplazo total.** El V1 automático (evaluador + catálogo JSON +
  overrides) se retira por completo. Las promos viven creadas por el usuario.
- **PA-02 Adjudicación universal.** Cualquier transacción (manual o importada)
  puede adjudicarse a una o más promos, en cualquier momento (crear o editar
  después). Sin adjudicación en lote en esta versión.
- **PA-03 Monto completo.** El monto íntegro de la tx cuenta en cada promo a la
  que se adjudique. Sin montos parciales.
- **PA-04 Suma con signo.** `avance(promo) = −Σ tx.amount` sobre adjudicaciones
  activas con `tx.deletedAt == nil`. Convención contable intacta (carga < 0,
  crédito > 0): compra −1,000 + devolución +200 → avance 800. Editar el monto
  de una tx adjudicada cambia el avance; el soft-delete la excluye y restaurarla
  la devuelve.
- **PA-05 Moneda explícita.** Cada promo declara su moneda (default: la de la
  cuenta ancla al crear). Solo pueden adjudicarsele tx de esa moneda — de
  cualquier cuenta. Sin conversión FX; nunca se suman divisas.
- **PA-06 Cuenta = ancla organizativa.** La promo pertenece a una cuenta para
  ubicarse en su dashboard, pero la cuenta no filtra adjudicaciones ni es
  dependencia dura (una promo con cuenta eliminada sigue visible, re-anclable).
- **PA-07 Ventana informativa.** La ventana (inicio/fin opcionales) produce el
  contador «día N de M» y un aviso al adjudicar fuera de ventana. No filtra el
  avance: cuenta todo lo adjudicado.
- **PA-08 Garantía honesta.** El usuario controla qué movimientos cuentan; el
  sistema no deduce elegibilidad ni evita toda duplicidad económica (una compra
  original y sus cuotas MSI pueden ambas estar adjudicadas). El drill-down
  lista cada contribución con monto y signo para que la revisión humana lo
  detecte. El doble conteo MSI se resuelve adjudicando el par original +
  reversión, que se neutralizan solos.
- **PA-09 Estados distintos.** `archivedAt` (oculta de cards, conserva
  historial, reactivable) ≠ `deletedAt` (tombstone de merge; sus adjudicaciones
  quedan huérfanas visibles que no cuentan).

## Modelo de datos

`Application Support/FinanceTracker/PromotionLedger.json` (patrón
`SpendRequirementStore`; cero schema SwiftData — AD-023):

```json
{ "schemaVersion": 1,
  "updatedAt": "...",
  "promotions": [{
    "id": "UUID", "name": "…", "accountID": "UUID", "currency": "MXN",
    "windowStart": "Date?", "windowEnd": "Date?",
    "targetAmount": "String?" (Decimal), "rewardNote": "String?", "notes": "String?",
    "archivedAt": "Date?", "createdAt": "Date", "updatedAt": "Date", "deletedAt": "Date?"
  }],
  "attributions": [{
    "id": "UUID", "promotionID": "UUID", "transactionID": "UUID",
    "createdAt": "Date", "updatedAt": "Date", "deletedAt": "Date?"
  }] }
```

- Llave natural `(promotionID, transactionID)`; adjudicar es upsert idempotente.
- Merge/restore determinista: gana mayor `updatedAt`, desempate por
  `id.uuidString` mayor (precedente `SettlementDueDateService`). Los duplicados
  de llave natural con distinto `id` se colapsan al ganador en load y en merge;
  `validate()` reporta la reparación.
- Huérfanos (promo eliminada o tx inexistente): se conservan en el archivo,
  visibles en Settings/Salud de datos, no contribuyen al avance, recuperables si
  la referencia reaparece.
- Archivo corrupto: fail-visible (error; sin reparación silenciosa).

## Protocolo de guardado (dos almacenes)

1. La transacción se guarda primero (`Persistence.save` throws). Solo tras el
   éxito se aplica la mutación del ledger.
2. Fallo del ledger tras guardar la tx: alerta «la transacción se guardó pero
   no se pudo adjudicar a X» con **Reintentar** (re-ejecuta solo el upsert,
   idempotente; jamás crea otra tx) y **Más tarde** (PA-02 es la red de
   seguridad).
3. Escritura `.atomic` del archivo completo; caché en memoria y notificación
   (`promotionLedgerDidChange`) solo tras escritura exitosa. Un retiro que
   falla deja el estado anterior intacto + error visible.
4. Los imports jamás tocan el ledger.

## Ventana (semántica exacta)

Días de calendario civil local (`startOfDay`, `TimeZone.current`), límites
inclusivos. Antes del inicio: «comienza el X (en N días)». Durante: «día N de
M» / «N días restantes». Después: «ventana cerrada el X». Sin ventana: sin
contador. Adjudicar fuera de ventana se permite con aviso inline.

## Backup y compatibilidad

- `BackupArchive.schemaVersion` 9 → **10**; guard de restore `1...10`.
- Export manifest 10: escribe `PromotionLedger` (archivo único con el settings
  completo, como `SpendRequirement`); NO escribe `PromotionOverrides`.
- `requiredModelNames`: `PromotionOverrides` requerido **solo para 8 ≤ v < 10**
  (hoy es ≥8; sin este ajuste un backup v10 exigiría un archivo retirado);
  `PromotionLedger` requerido **≥10**.
- Restore `replaceAll` con backup ≤9 → ledger vacío (explícito, sin error).
  Restore `mergeKeepingNewer` con backup ≤9 → ledger local conservado íntegro.
- `PromotionOverrides.json` antiguo: jamás reinterpretado como adjudicaciones;
  en el primer arranque tras el upgrade se renombra a
  `PromotionOverrides.retired-<fecha>.json` (copia recuperable).
- Fallo de restore: el JSON previo del ledger se retiene antes de escribir; si
  cualquier etapa falla, se restaura el contenido anterior + error visible.
- `AppDataResetService`: borrar el archivo del ledger y verificar (mismos
  puntos donde hoy se tratan `PromotionOverrides`/`SpendRequirement`).

## UI (4 superficies, es-MX)

1. **Card «Promociones»** en el dashboard de tarjeta (reemplaza la del V1):
   fila por promo activa — nombre, avance/meta en su moneda, día N/M, marca de
   adjudicaciones fuera de ventana. Tap → drill-down (reutiliza el nombre
   `PromotionDetailSheet`): lista de adjudicaciones (fecha, descripción,
   monto, aporte con signo, fuera-de-ventana atenuada, huérfanas marcadas),
   total, editar, archivar.
2. **Hoja crear/editar** (`PromotionEditorSheet`): nombre, cuenta, moneda
   (default de la cuenta), ventana, meta, recompensa/notas.
3. **Multi-select «Promociones»** en `ManualTransactionSheet` (reemplaza el
   live preview del V1) y `TransactionDetailSheet`: solo promos activas de la
   misma moneda que la tx; aviso inline fuera de ventana; badge discreto en
   filas adjudicadas de la tabla.
4. **Settings → «Promociones»** (reemplaza `PromotionHealthSection`): lista
   completa — activas, archivadas, cuenta eliminada (re-anclable);
   editar/archivar/reactivar/eliminar.

## Demolición V1 (último paso, gated)

Solo tras la verificación completa (build + suite serial + backup round-trips):

- Fuera: `FinanceTracker/Domain/Promotions/` (Evaluator, Definition, Catalog),
  `Catalog/*.json`, `Utilities/PromotionStore.swift`,
  `Features/Settings/PromotionHealthSection.swift`, wiring en
  `DashboardViewModel`, `DashboardSnapshot`, `SettingsView`,
  `ManualTransactionSheet`, `PromotionsCard`, entradas `Domain/Promotions/Catalog`
  de resources en `project.yml` (ambos targets), y las 9 suites en
  `FinanceTrackerTests/PromotionTests/` (las de catalog/evaluator).
- Se queda: `SpendRequirementStore`, `SpendRequirementEditorSheet`,
  card-pace insights (gasto mínimo anual — independiente de promos).
- `promo.py`: extraer `MSI_RULES` + `resolve_rule_targets` +
  `categorize_with_rules` a `.claude/skills/finanzas/_shared/msi_rules.py`;
  re-apuntar writeback y `test_msi_rules.py`; borrar `habits/scripts/promo.py`
  y `tests/finanzas/test_promo.py`; limpiar `conftest.py` y docs del skill.

## Matriz de aceptación (tests obligatorios)

1. **Signos:** cargo avanza, crédito resta, mixto (−1,000 + +200 → 800);
   edición de monto propaga; soft-delete excluye y restore reintegra;
   multi-promo independiente; tx de otra moneda inadjudicable.
2. **Ledger:** upsert idempotente por llave natural; merge con tombstones,
   empates de `updatedAt` (desempate id), duplicados cross-id colapsados;
   archivo corrupto fail-visible; huérfanas visibles y sin aporte.
3. **Ventana:** días civiles locales a través de DST; límites inclusivos;
   presentaciones antes/durante/después/sin ventana; adjudicación fuera de
   ventana permitida con aviso.
4. **Protocolo:** tx guardada + ledger fallido → error con Reintentar que no
   duplica la tx.
5. **Backup:** round-trip manifest 10 (export → restore replaceAll y merge);
   ≤9 en ambos modos (vacío / conservado); reset clean slate.
6. **Suite serial completa** + `poetry run pytest tests/finanzas` verde tras el
   retiro de promo.py.

## Non-goals

Sin montos parciales, sin adjudicación en lote, sin conversión FX, sin
proyecciones de cuotas, sin recibo/persistencia de recompensas, sin tocar el
schema SwiftData (`Transaction` sigue congelado — AD-023), sin borrar
`SpendRequirementStore` (no es de promos).
