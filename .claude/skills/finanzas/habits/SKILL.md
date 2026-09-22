---
name: finanzas-habits
description: Sub-skill de hábitos de gasto del cerebro financiero. Diagnóstico de en qué se gasta el dinero — top comercios, suscripciones/recurrentes, fugas, deltas categoría mes-a-mes. No cargar directamente; el router finanzas/SKILL.md despacha aquí.
---

# /finanzas hábitos — diagnóstico de gasto

Esta sub-skill responde preguntas sobre **en qué se gasta** el dinero. Es lo que la app
NO hace: agrupa por comerciante (no solo por categoría), detecta recurrentes, y muestra
deltas mes-a-mes más allá del umbral ±30% de la app.

## Cómo trabajar

1. Carga el dataset con `_shared/load.py` (`load_dataset()`).
2. Para toda agregación, pasa por `_shared/accounting_gates.classify()` — solo cuenta
   `counts_as_regular_expense`. **Nunca** sumes `amount<0` crudo (duplicarías transferencias).
3. Etiqueta cada afirmación con nivel de certeza (Hecho/Derivado/Inferido/Supuesto).
4. Respalda cada número con `_shared/trace.py`.

## Agregaciones disponibles (`scripts/aggregate.py`)

```python
from _shared.load import load_dataset, live_transactions
from _shared.accounting_gates import classify, account_from_snapshot, category_from_snapshot
import sys; sys.path.insert(0, 'habits/scripts'); import aggregate as H

ds = load_dataset()
txs = live_transactions(ds)

H.top_merchants(txs, ds, months=3)         # top comercios por gasto (Hecho → Derivado)
H.spending_by_category(txs, ds, months=3)  # gasto por categoría (para deltas)
H.recurring(txs, ds)                        # suscripciones/gastos recurrentes (Inferido)
H.mom_delta(txs, ds)                        # cambio mes-a-mes por categoría
```

## Tracker de promociones (`scripts/promo.py`)

Para preguntas "¿cómo voy de la promo X?": gasto bruto vs elegible, avance contra metas,
días restantes y riesgos de conversión MSI. Clasifica por patrón primero (la categoría
puede mentir); nunca recomienda gasto artificial:

```bash
python3 .claude/skills/finanzas/habits/scripts/promo.py \
  --account "The Platinum Credit Card" --start 2026-09-09 --days 90 \
  --targets 100000,105000,110000
```

Los specs de reglas MSI (`promo.MSI_RULES`) son la fuente canónica para crear CategoryRule
vía `writeback.apply_category_rules` + `promo.resolve_rule_targets`. Como las categorías
vienen duplicadas (household), pasa `prefer_ids` con los categoryIds que ya usan las
transacciones de la cuenta (continuidad), no la primera instancia del archivo.

## Certeza por agregación

| Agregación | Nivel | Por qué |
|------------|-------|---------|
| top comercios | Hecho (los montos) + Derivado (el ranking) | montos importados; ranking es cálculo |
| recurrentes | **Inferido** | "parece una suscripción" — no hay entidad recurrente declarada; dilo así |
| deltas MoM | Derivado | cálculo sobre hechos |
| "esta compra es discrecional" | Inferido/Supuesto | juicio, no dato |

## Reglas específicas

- **Recurrentes = Inferido**: no existe entidad de suscripción en la app. Detecta mismo
  merchant + monto similar + periodicidad mensual, y preséntalo como "parece recurrente".
  No afirmes "es una suscripción" sin verificación del usuario.
- **Mes actual incompleto**: los datos llegan hasta la última importación (revisa el rango
  temporal del dataset), no hasta hoy. Si el mes en curso muestra categorías en $0 (renta,
  seguro, etc.), suele ser "aún no se ha importado/cobrado", no "dejaste de pagar".
  Verifica la fecha de la última transacción antes de interpretar un delta negativo grande.
- **Sin cobertura = no es cero**: si un mes falta un comerciante, puede ser "no gasté" o
  "no importé el estado". Distingue: si el período tiene transacciones pero el comerciante
  no aparece → probablemente no gastaste; si el período está vacío → faltan datos.
- **FX**: si hay cuentas no-MXN, los montos no están normalizados (`fxRateToBase` suele ser 1).
  Etiqueta "asumiendo todo MXN" o convierte con `fxRateToBase` y márcalo.
