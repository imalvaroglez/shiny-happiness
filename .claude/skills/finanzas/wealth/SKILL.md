---
name: finanzas-wealth
description: Sub-skill de patrimonio del cerebro financiero. Crecimiento de net worth (CAGR), composición liquidez/patrimonial/retiro/pasivo, rendimiento de posiciones bursátiles, runway de liquidez. No cargar directamente; el router finanzas/SKILL.md despacha aquí.
---

# /finanzas patrimonio — cómo crece el net worth

Responde "¿cómo va mi patrimonio?", "¿cuánto creció?", "¿cómo está compuesto?", "¿qué tal
rinden mis inversiones?". El patrimonio es **puntual** (saldos resueltos a una fecha), NO
suma de transacciones.

## Cómo trabajar

1. `_shared/load.py`.
2. Los saldos vienen de `AccountBalanceSnapshot` (y `Statement.closingBalance` para tarjetas).
   Usa `net_worth_at(ds, fecha)` y `composition(ds)` en `scripts/aggregate.py` — ya resuelven.
3. **Patrimonio es Hecho** cuando viene de snapshot exacto; **Derivado** cuando se reconstruye.
4. Respeta `includeInNetWorth` por cuenta (algunas pueden estar excluidas).

## Agregaciones (`scripts/aggregate.py`)

```python
import sys, os; sys.path.insert(0, os.path.abspath('_shared')); sys.path.insert(0, os.path.abspath('wealth/scripts'))
from load import load_dataset
import aggregate as W
ds = load_dataset()

W.net_worth_series(ds)       # net worth a lo largo del tiempo (por snapshot dates)
W.composition(ds)            # liquidez / patrimonial / retiro / pasivo (Derivado)
W.cagr(ds)                   # crecimiento anualizado (Derivado/Supuesto según ventana)
W.positions(ds)              # posiciones bursátiles con costo/valor/crecimiento (Derivado)
W.liquidity_runway(ds, txs)  # meses de gastos cubiertos por liquidez (Derivado)
W.available_net_worth(ds)    # net worth excluyendo retiro (la métrica hero de la app)
```

## Reglas específicas

- **Net worth ≠ suma de transacciones**. Es Σ de saldos resueltos a una fecha. Nunca lo
  expliques como deltas de transacciones.
- **Composición** (como NetWorthComposition.swift): liquidez (activo líquido no-retiro),
  patrimonial (inversión no-líquida), retiro (type=retirement), pasivo (tarjeta/préstamo).
  `availableNetWorth = netLiquidity + patrimonial` (excluye retiro — no es tocable).
- **CAGR**: solo significativo con ventana ≥ 6 meses. Con menos, reportar crecimiento absoluto
  y "CAGR proyectado, Supuesto".
- **Posiciones**: `growth` usa `lastPrice` que puede estar desactualizado (`lastPriceAt`).
  Si `lastPriceAt` es antiguo, marcar "valuación posiblemente desactualizada".
- **Runway de liquidez**: liquidez / gasto mensual promedio (de la sub-skill ingresos).
  Supuesto: asume gasto constante.
- **Snapshot fresco**: GBM y Morgan Stanley se actualizan seguido (11 snaps); tarjetas y
  algunos bancos menos. El net worth "actual" depende de qué tan fresco sea cada snapshot.
