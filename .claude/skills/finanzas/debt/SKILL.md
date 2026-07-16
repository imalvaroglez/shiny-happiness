---
name: finanzas-debt
description: Sub-skill de deuda del cerebro financiero. Estrategia de salida de tarjetas/préstamos — utilización, pago-para-no-generar-intereses, avalancha/bola de nieve, runway, burden de MSI. No cargar directamente; el router finanzas/SKILL.md despacha aquí.
---

# /finanzas deuda — estrategia de salida

Responde "¿cómo salgo de las tarjetas?", "¿cuánta presión de deuda tengo?", "¿qué tarjeta
atacar primero?". Combina saldos, intereses reales de estados, y límites de crédito.

## Cómo trabajar

1. `_shared/load.py` para el dataset.
2. Los saldos de tarjetas requieren **combinar** `Statement.closingBalance` (cuando existe)
   y `AccountBalanceSnapshot` (cuando el estado no trae saldo). Usa `liability_balances()`
   en `scripts/aggregate.py` — ya hace la resolución.
3. Niveles de certeza: el saldo de cierre es **Hecho**; la proyección de salida es **Supuesto**
   (asume que no agregas cargos y que el interés se mantiene).

## Agregaciones (`scripts/aggregate.py`)

```python
import sys, os; sys.path.insert(0, os.path.abspath('_shared')); sys.path.insert(0, os.path.abspath('debt/scripts'))
from load import load_dataset, live_transactions
import aggregate as D
ds = load_dataset()

D.liability_balances(ds)        # saldo actual por tarjeta (Hecho) + utilización + pago-para-no-generar-intereses
D.avalanche(ds, monthly_budget) # orden de ataque por interés (Supuesto)
D.snowball(ds, monthly_budget)  # orden de ataque por saldo menor (Supuesto)
D.runway(ds)                    # meses al pago-para-no-generar-intereses (Derivado)
```

## Reglas específicas

- **Pago para no generar intereses (PGI)**: en México, si pagas el PGI no hay intereses.
  Reportar siempre: "si pagas $X este mes, no generas intereses". El interés real solo
  aplica al saldo que excede el PGI o si no lo pagas.
- **Interés real**: usar `Statement.interestCharged` cuando exista. Si es `None`, la tarjeta
  pudo haberse pagado en PGI (cero interés) — no asumir tasa.
- **Avalancha vs bola de nieve**: avalancha = mayor interés primero (óptimo matemáticamente);
  bola de nieve = menor saldo primero (mejor psicológicamente). Presentar ambos y dejar que
  el usuario elija. Ambos son **Supuesto**: asumen budget fijo, sin cargos nuevos.
- **Saldo reconstruido**: si el saldo viene de snapshot (no de closingBalance), marcar
  "calculado a partir del último snapshot de balance".
- **MSI**: si hay planes MSI activos, los cargos futuros son compromiso firme (no
  cancelables sin penalización). Incluirlos en el burden mensual.
