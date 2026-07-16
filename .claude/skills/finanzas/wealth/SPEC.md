# SPEC — Análisis de productos (wealth)

Especificación **normativa** del comportamiento del análisis de productos de
ahorro / cuentas remuneradas / fondos de liquidez / inversión de corto plazo
dentro de la sub-skill `wealth`. Las funciones en `scripts/products.py` son la
implementación de referencia de estas reglas; `scripts/balance.py` es la del
saldo reconstruido. Los tests (`tests/finanzas/wealth/`) anclan cada regla.

Esto **no** reemplaza al router (`finanzas/SKILL.md`): las reglas cross-cutting
de certeza, gates contables, trazabilidad, solo-lectura y privacidad se asumen
y se referencian. Aquí se definen las reglas **específicas del dominio
producto**.

---

## 0. Modos de fallo que este SPEC previene

Estos son los 10 errores observados que motivan el spec. Cada uno está cubierto
por ≥1 regla y ≥1 test.

| # | Fallo | Regla que lo previene | Test |
|---|-------|----------------------|------|
| 1 | Leer "GAT vigente al 31 oct" como garantía de tasa hasta esa fecha | R2, R3 | caso 1 |
| 2 | Leer la banda >$500k @0% como "bajará a 0% en noviembre" | R4, R10 | caso 2 |
| 3 | Comparar $499,900 vs $519,643 como si fueran el mismo capital | R6 | caso 3 |
| 4 | Decidir mover todo Openbank por su tasa promedio 8.19% | R5 | caso 5 |
| 5 | Reportar $712 en lugar de $7,207 (error ×10) | R7 | caso 4 |
| 6 | Recomendar $5,758 de fondo de emergencia sin modelar liquidez | R11 | caso 7 |
| 7 | Presentar un rendimiento de 108 días como tasa constante garantizada | R3, R8 | caso 1, 9 |
| 8 | Confundir BondDia con CETE a tasa fija | R14 | caso 10 |
| 9 | Restar 0.5% de retención como si fuera ISR definitivo neto | R13 | caso 8 |
| 10 | No detectar que $499,900 @10% cruza $500k por intereses | R10 | caso 6 |

---

## 1. Modelo de datos (resumen)

Definido en `scripts/products.py`. Dinero siempre `Decimal`; **tasas como
fracción** (0.13, no 13).

- `Tier(lower, upper, rate_annual, rate_nature, note)` — un rango de saldo.
- `TierApplication ∈ {MARGINAL, WHOLE_BALANCE, UNKNOWN}` — cómo se aplican los tramos.
- `RateNature ∈ {NOMINAL_ANNUAL, EFFECTIVE_ANNUAL, GROSS_PERIOD, UNKNOWN}`.
- `RateFixity ∈ {FIXED_CONTRACTUAL, FIXED_PROMOTIONAL, VARIABLE, UNKNOWN}`.
- `TaxBasis ∈ {GROSS, PROVISIONAL_WITHHOLDING, DEFINITIVE_ANNUAL, UNKNOWN}`.
- `LiquidityProfile(access, weekend_access, settlement_days, penalty, withdrawal_limit, ...)`.
- `ProductTerms(product_id, product_kind, rate_tiers, tier_application, rate_fixity,
  rate_guaranteed_until, disclosure_valid_until, subject_to_change, rate_nature,
  tax_basis, withholding_rate, day_count_basis, currency, liquidity, source_text, ...)`.
- `ScenarioAllocation / ScenarioResult / ComparisonValidation / ThresholdRisk /
  Confidence / LiquidityClassification / ProductAnalysisOutput` (ver products.py).

---

## 2. Reglas normativas

### R1 — Separación Hecho / Inferencia / Supuesto / No-confirmado
Toda afirmación relevante se clasifica. **Hecho**: textual en la fuente.
**Inferencia**: derivada, marcada, con evidencia. **Supuesto**: adoptado para
calcular (aparece ANTES del resultado que depende de él). **No-confirmado**:
necesario pero no deducible — **nunca** se promueve a Hecho. Mapea al router
(Hecho/Derivado/Inferido/Supuesto) con `NO_CONFIRMADO` añadido.

### R2 — Vigencia informativa ≠ garantía contractual
`disclosure_valid_until` ("GAT vigente al `<date>`", fecha de cálculo, vigencia
de folleto) **no es** `rate_guaranteed_until`. Solo es garantía si el texto lo
dice inequívocamente: "tasa garantizada hasta", "vigente para el cliente hasta",
"plazo de X días con tasa fija", "la tasa contratada se mantendrá hasta el
vencimiento".

### R3 — No-extrapolación temporal
Frases "sujeta a cambios sin previo aviso", "para fines informativos y de
comparación", "GAT vigente al", "fecha de cálculo" → emitir advertencia de que
la tasa futura no está garantizada. **Prohibido** generar "la tasa vence el
31/10", "bajará a 0% en noviembre", "queda fija hasta esa fecha" salvo fuente
explícita. `subject_to_change=True` fuerza `RateFixity != FIXED_CONTRACTUAL`.

### R4 — Interpretación de tablas de rangos
Distinguir `MARGINAL` (cada tasa a la porción del saldo en su banda) de
`WHOLE_BALANCE` (una tasa al saldo completo según el rango donde cae el total).
Si el texto no aclara → `UNKNOWN`: **no** elegir en silencio; modelar ambas si
son materialmente distintas; señalar la más conservadora; formular la pregunta
contractual; evitar recomendación irreversible.

### R5 — Marginal, no solo promedio
Calcular: rendimiento total actual, tasa efectiva promedio, **tasa marginal por
tramo**, rendimiento incremental de mover cada tramo. Nunca decidir mover un
saldo entero solo por su tasa promedio. `average_rate` se expone **solo** como
contraste de auditoría ("la vista de promedio, incorrecta, diría X").

### R6 — Comparabilidad de escenarios
Antes de comparar: `|total_A − total_B| ≤ 0.01` (tolerancia de redondeo). Si
difieren: detener, identificar el capital faltante/excedente, explicar dónde
permanece, recalcular sobre la misma base. Detectar capital omitido, doble
conteo, capital tratado como invertido+y+líquido, horizontes desalineados.

### R7 — Sanity de cálculo y orden de magnitud
`beneficio_anual = P × (r2 − r1)`; `beneficio_periodo = P × (r2 − r1) × días / base`.
Recalcificar por **dos rutas independientes** (interés simple vs `P×r×t/base`).
Detectar factor ×10/×100, porcentaje-vs-decimal (0.0357 no 3.57 ni 0.00357),
360-vs-365, doble anualización. Si `P × delta_rate` difiere >1% del reportado →
error. Mostrar fórmulas intermedias en modo auditoría.

### R8 — Tasas futuras inciertas
Tasa variable / "sujeta a cambios" → no presentar un único rendimiento futuro
como certeza. Escenarios: **base** (tasa actual), **conservador** (tasa baja
conocida), **punto de equilibrio** (tiempo para compensar fricción/pérdida de
liquidez). Si hay fecha anunciada de reducción, modelar por segmentos; si la
fecha es desconocida, usar un **rango**, nunca una fecha inventada.

### R9 — Capitalización vs GAT
Distinguir nominal / bruta / efectiva / GAT nominal / GAT real / rendimiento de
periodo corto / después de impuestos. No usar la GAT nominal como tasa aplicable
directamente en un periodo de pocos meses. Para corto plazo usar tasa
contractual, periodicidad, frecuencia de capitalización, días efectivos. Si la
periodicidad es desconocida → interés simple aproximado + rango + aclaración.

### R10 — Riesgo de cruzar umbrales
Productos con pérdida abrupta de tasa al superar un límite: calcular margen de
seguridad. Evaluar si los intereses se suman al saldo, interés diario/mensual,
en cuánto tiempo se cruza el umbral, frecuencia de revisión de banda, si pierde
tasa solo el excedente o todo el saldo. **Alerta severa** cuando
`inicial + intereses ≥ límite`. Sin claridad contractual → sugerir margen
conservador, no recomendar el máximo exacto.

### R11 — Liquidez y fondo de emergencia
Clasificar cada producto por `LiquidityProfile`. Separar liquidez operativa /
fondo de emergencia / liquidez táctica / capital optimizable / capital a plazo.
Si el gasto mensual o fondo objetivo es desconocido → **no** recomendar dejar
una cantidad nominal arbitraria; mostrar impacto de 1/3/6 meses; señalar el dato
faltante; recomendación provisional condicionada. `classify_liquidity` devuelve
`"unevaluable"` cuando no se puede evaluar.

### R12 — Diversificación institucional
Considerar concentración por institución, protección aplicable, naturaleza
(banco / fondo / fintech), riesgo operativo, dependencia de tasa promocional.
Incluir nota de concentración al mover una proporción material a una sola
institución. No inventar cobertura — marcar pendiente.

### R13 — Tratamiento fiscal
Separar bruto / retención provisional / impuesto definitivo / interés real /
efecto de inflación / situación individual. No restar retención como ISR
definitivo. Prohibido "neto después de ISR" sin base legal + tasa correcta +
método + periodo + naturaleza + datos del contribuyente. Si faltan → decir
"rendimiento bruto", "retención estimada, no necesariamente impuesto definitivo".

### R14 — Clasificación de productos
Distinguir cuenta bancaria remunerada / depósito a la vista / pagaré / fondo de
inversión de deuda / CETE / bono / fondo diario / fintech / plazo. No describir
BondDia como CETE individual a tasa fija. Si el nombre comercial no basta →
descripción neutral + clasificación pendiente.

---

## 3. Contrato de salida A–H

`assemble_output()` produce `ProductAnalysisOutput` con:

- **A. Datos confirmados** — institución, producto, saldo, tasa actual, tipo de
  tasa, estructura (marginal/saldo total), liquidez, vigencia confirmada, fuente.
- **B. Datos no confirmados** — preguntas contractuales pendientes.
- **C. Validaciones** — suma de saldos, capital por escenario, igualdad de
  capitales, fechas, días, base de días, capitalización, impuestos excluidos/modelados.
- **D. Rendimiento actual** — por cuenta y por tramo.
- **E. Opciones de movimiento** — por tramo: origen, destino, capital, tasa
  origen/destino, diferencia, beneficio anual, beneficio del periodo, pérdida de
  liquidez, riesgo, confianza.
- **F. Escenarios** — conservador / base / favorable.
- **G. Recomendación** — óptimo financiero / prudente / condiciones que invalidan.
- **H. Alertas** — umbral, tasa no garantizada, concentración, liquidez, impuestos,
  información faltante.

---

## 4. Prohibiciones de lenguaje

Prohibido salvo verificación: "definitivamente", "garantizado", "vence", "bajará",
"conviene", "no conviene", "ganarás", "neto después de impuestos".
Preferir: "bajo este supuesto", "si la tasa se mantiene", "parece", "la lectura
conservadora es", "la fuente no confirma", "el resultado estimado sería",
"financieramente mejora, pero reduce liquidez".

---

## 5. Confidence scoring

Por dimensión (0.0–1.0): extracción de tasa, interpretación de tramos, horizonte,
liquidez, fiscal, recomendación. `overall = min(...)`. La confianza matemática no
se confunde con la contractual. Si `overall < 0.6` → lenguaje condicionado +
incluir bloque de auditoría.

---

## 6. Modo auditoría

Verbose: texto fuente relevante, campos extraídos, clasificación de cada dato,
fórmulas, unidades, conversiones porcentuales, asignación de capital por slice,
días, base de días, redondeos, validaciones, advertencias, confianza por dimensión.

Ejemplo:
```
Fuente: "GAT vigente al 31 de octubre de 2026."
Clasificación: disclosure_valid_until = 2026-10-31
No clasificado como: rate_guaranteed_until
Motivo: la fuente también dice "tasa sujeta a cambios sin previo aviso".
```

---

## 7. Saldo reconstruido (`balance.py`)

Puerto de `FinanceTracker/Domain/Services/AccountBalanceResolver.swift`
(referencia canónica). Algoritmo:

1. **Anchors** = statements con `closingBalance` (`periodEnd`, `closingBalance`)
   + snapshots (`date`, `amount`, `kind`), excluyendo snapshots cuyo `id`
   colisiona con un `Transaction.id` soft-deleted (deleted-mirror).
2. **Tx que cuentan** = `accountId == acct`, `statementId is None`,
   `isDuplicate False`, `deletedAt None`, ordenadas por `postedAt` asc, signos
   **tal cual** (sin re-signar; los signos se fijan en ingest).
3. **Anchor elegido** = el de mayor `date` con `date ≤ as_of` (comparación cruda
   UTC, igual que Swift).
4. Ramas: (a) `portfolioValuation` → monto tal cual, sin deltas (corre primero);
   (b) sin anchors de statement **en absoluto** y primer anchor `manualOpening`
   → B1 (anchor posterior) / B2 (desde `openedAt`); (c) general
   `base = anchor.amount si hay anchor si no 0`, `Σ amount` con
   `anchor_date < postedAt ≤ as_of`; (d) sin anchor y sin tx → historial
   insuficiente.
5. `source_kind ∈ {exact, latest_prior, reconstructed, insufficient}`;
   `source_date` = fecha del anchor ("Starting snapshot").

**Limitación conocida**: suma naive entre monedas (no hay FX). Documentado, no se
inventa conversión.
