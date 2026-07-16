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

## Análisis de productos (ahorro / remuneradas / liquidez / corto plazo)

Cuando el usuario pregunte "¿conviene mover X a Y?", compare dos productos, o pida
rendimiento de una cuenta remunerada/fondo/depósito a corto plazo, **usa las funciones
puras de `scripts/products.py`**. El spec normativo completo está en `SPEC.md`; estas
son las reglas operativas.

**Flujo:** extrae `ProductTerms` desde el texto fuente (Hecho si está citado, si no
`No_confirmado`) → `build_scenario` por tramo → `validate_comparison` (capitales
iguales) → `base_conservative_break_even` → `sanity_check` (magnitud) →
`threshold_risk` (umbrales) → `classify_liquidity` → `score_confidence` →
`assemble_output`. **El modelo llena `ProductTerms`; las funciones hacen TODA la
matemática.** Nunca decidas mover un saldo entero por su tasa promedio — usa
`marginal_incremental_return` sobre el slice que se mueve.

Reglas no negociables (detalle y los 10 fallos que previenen en `SPEC.md` §0/§2):

- **Vigencia informativa ≠ garantía.** `disclosure_valid_until` ("GAT vigente al
  `<date>`", fecha de cálculo) **no es** `rate_guaranteed_until`. "Sujeta a cambios"
  → la tasa futura no está garantizada.
- **Bandas vs tramos.** Si el texto no aclara si la tabla es marginal o por saldo
  total → `TierApplication.UNKNOWN`: modela ambas, marca ambigüedad, no elijas.
- **Comparabilidad.** Antes de un delta de rendimiento, `|capital_A − capital_B| ≤ 0.01`.
- **Sanity de magnitud.** `sanity_check` recalcifica por dos rutas y caza errores
  ×10/×100, porcentaje-vs-decimal, 360-vs-365. Tasas como **fracción** (0.10, no 10).
- **Umbrales.** Si el producto pierde tasa al superar un límite, `threshold_risk`
  alerta cuando `inicial + intereses ≥ límite` (crítico si cruza en <1 día).
- **Liquidez.** `classify_liquidity` devuelve `"unevaluable"` sin gasto mensual —
  **nunca** apruebes un fondo de emergencia mínimo arbitrario.
- **Fiscal.** Separa bruto / retención provisional / ISR definitivo. Nunca "neto
  después de ISR" sin base legal.
- **Clasificación.** `product_kind` neutro; BondDia es `debt_fund` pendiente de
  verificar, **no** "CETE a tasa fija".

## Estructura de salida A–H

`assemble_output` produce siempre estas secciones (mapea a `ProductAnalysisOutput`):

- **A. Datos confirmados** — institución, producto, saldo, tasa actual, tipo de tasa,
  estructura (marginal/saldo total), liquidez, vigencia confirmada, fuente.
- **B. Datos no confirmados** — preguntas contractuales pendientes.
- **C. Validaciones** — suma de saldos, capital por escenario, igualdad de capitales,
  fechas, días, base de días, capitalización, impuestos.
- **D. Rendimiento actual** — por cuenta y por tramo.
- **E. Opciones de movimiento** — por tramo: origen, destino, capital, tasas,
  diferencia, beneficio anual y del periodo, pérdida de liquidez, riesgo, confianza.
- **F. Escenarios** — conservador / base / favorable.
- **G. Recomendación** — óptimo financiero / prudente / condiciones que invalidan.
  Siempre **condicional** ("si la tasa se mantiene").
- **H. Alertas** — umbral, tasa no garantizada, concentración, liquidez, impuestos,
  información faltante.

Si `confidence.overall < 0.6` (o si el usuario lo pide), pasa `audit=True` e incluye
el bloque de auditoría (fuente, campos extraídos, fórmulas, unidades, confianza).

## Prohibiciones de lenguaje (productos)

Evita salvo verificación explícita: "definitivamente", "garantizado", "vence",
"bajará", "conviene", "no conviene", "ganarás", "neto después de impuestos".
Preferir: "bajo este supuesto", "si la tasa se mantiene", "parece", "la lectura
conservadora es", "la fuente no confirma", "el resultado estimado sería",
"financieramente mejora, pero reduce liquidez". La lista literal vive en
`products.BANNED_PHRASES`. Esto **extiende** las reglas cross-cutting de certeza del
router para el dominio producto; no las reemplaza.

## Saldo reconstruido

Los saldos vienen de `scripts/balance.py` (puerto de
`AccountBalanceResolver.swift`): anchor (snapshot/statement) **+ transacciones
posteriores**, no solo el último snapshot. Si un saldo luce congelado respecto a la
app en vivo, probablemente el `.ftbackup` exportado no incluye movimientos recientes
— pide al usuario uno más fresco o el saldo actual. Algoritmo y limitaciones en
`SPEC.md` §7.
