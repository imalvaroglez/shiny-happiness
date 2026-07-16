---
name: finanzas-income
description: Sub-skill de ingresos del cerebro financiero. Diversificación de fuentes de ingreso, estabilidad, dependencia de una sola fuente, y savings rate (tasa de ahorro) como serie. No cargar directamente; el router finanzas/SKILL.md despacha aquí.
---

# /finanzas ingresos — de dónde viene el dinero

Responde "¿de dónde viene mi ingreso?", "¿qué tan dependiente soy de mi sueldo?",
"¿cuánto estoy ahorrando?". Desglosa ingreso por subcategoría y por cuenta, mide estabilidad.

## Cómo trabajar

1. `_shared/load.py`.
2. Para todo ingreso, pasa `accounting_gates.classify()` — solo `counts_as_regular_income`.
   Excluye interests si son investmentReturn, retirement contributions, etc.
3. **Fuente de ingreso = Inferido**: no hay entidad formal de empleador/cliente. La
   subcategoría Income (Salary/Compensation/Freelance/Interest/Refund) es la mejor señal,
   pero atribuir "esto es salario de X" es inferencia.

## Agregaciones (`scripts/aggregate.py`)

```python
import sys, os; sys.path.insert(0, os.path.abspath('_shared')); sys.path.insert(0, os.path.abspath('income/scripts'))
from load import load_dataset, live_transactions
import aggregate as I
ds = load_dataset(); txs = live_transactions(ds)

I.by_source(txs, ds)              # ingreso por subcategoría Income (Hecho→Derivado)
I.monthly_series(txs, ds)         # ingreso/gasto/ahorro por mes (Derivado)
I.savings_rate(txs, ds)           # tasa de ahorro por mes (Derivado)
I.concentration(txs, ds)          # % del ingreso que viene de 1 sola fuente (Derivado)
```

## Reglas específicas

- **Savings rate = (ingreso − gasto) / ingreso**, sobre `counts_as_regular_income/expense`.
  Solo es válido cuando el mes está completo (ver caveat de mes incompleto en hábitos).
- **Concentración**: si >80% del ingreso viene de una subcategoría → dependencia alta.
  Etiquetar como riesgo (Supuesto: "si esa fuente se interrumpe...").
- **Estabilidad**: coeficiente de variación del ingreso mensual. Bajo = estable.
- **Interest**: separar interés de cuentas (`Income.Interest`, regular) de investmentReturn
  (treatment tag, no regular income) — no mezclarlos.
- **Fer NO es ingreso del usuario**: `HouseholdPartnerIncomeEstimate` es la estimación de
  ingreso de Fer para el cálculo de reembolso. NUNCA sumarlo al ingreso del usuario. Si se
  menciona, etiquetar como Supuesto y separado del flujo real.
