---
name: finanzas
description: Cerebro financiero para FinanceTracker. Analiza el .ftbackup de la app — en qué se gasta, de dónde viene el ingreso, cómo salir de deudas y cómo crecer el patrimonio. Usar SIEMPRE que el usuario pregunte sobre sus finanzas personales, gastos, ingresos, ahorro, patrimonio, deudas, tarjetas, presupuestos, comercios, suscripciones o quiera un informe/revisión. Lee datos locales; nada sale de la máquina.
---

# /finanzas — Cerebro financiero de FinanceTracker

Analista financiero conversacional sobre los datos reales de la app FinanceTracker.
Lee el `.ftbackup` local, aplica los invariantes contables de la app, y razona con
trazabilidad a las transacciones concretas.

## Despacho — carga SOLO la sub-skill que corresponde

Después de identificar la intención del usuario, carga **una** sub-skill (lee su `SKILL.md`).
Si la pregunta cruza varios dominios o pides "un informe"/"revisión del mes", carga `review/`.

| Sub-skill | Carpeta | Foco | Cuándo despachar aquí |
|-----------|---------|------|-----------------------|
| **hábitos** | `habits/` | diagnóstico de gasto | "¿en qué gasté?", "subió X", fugas, comercios, suscripciones recurrentes, deltas mes-a-mes |
| **deuda** | `debt/` | estrategia de salida | "¿cómo salgo de la tarjeta?", runway, avalancha/bola de nieve, pago-para-no-generar-intereses, utilización |
| **patrimonio** | `wealth/` | crecimiento net worth | CAGR, composición liquidez/patrimonial/retiro, rendimiento de posiciones, runway de liquidez |
| **ingresos** | `income/` | diversificación de fuentes | "¿de dónde viene mi dinero?", dependencia de una fuente, estabilidad, savings rate |
| **informe** | `review/` | revisión de período | "dame un informe", "revisión del mes/trimestre", visión integrada |
| **reclasificar** | `recategorize/` | corregir categorías | "esto está mal categorizado", detectar miscategorizaciones, proponer reclasificación |

**Regla**: no cargues todas. Carga la mínima. Cada sub-skill es independiente.

## Reglas cross-cutting — TODA sub-skill debe cumplirlas

Estos puntos viven aquí para no repetirse; cada sub-skill los asume.

### 1. Pasar por los gates contables (`_shared/accounting_gates.py`)

La app excluye ciertas transacciones del ingreso/gasto/flujo de caja. Replicar esto
**no es opcional** — sin él, duplicarías transferencias como gasto y pagos de tarjeta
como ingreso (el error #1 en análisis financiero). Todo agregado pasa por
`accounting_gates.classify(tx, account, category)` antes de sumar.

Resumen de lo que se excluye del ingreso/gasto ordinario:
- soft-deletes (`deletedAt != nil`) y duplicados (`isDuplicate`)
- transferencias (`isTransfer` o `category.kind == transfer`)
- pagos de tarjeta (`category.kind == creditCardPayment`)
- movimientos entre cuentas propias (regex STP/BANAMEX/CUENTA titular)
- compras MSI sintetizadas (`installmentPlanId` + `|amount| == plan.originalAmount`)
- treatments: retirement contributions, investment returns, valuation adjustments, fees
- cuentas con `includeInCashFlow == false`

Los signos: cuentas activo → monto>0 ingreso, <0 gasto. Cuentas pasivo (tarjeta/préstamo)
→ monto<0 cargo, >0 pago. `Statement.closingBalance` se guarda negativo.

### 2. Etiquetar cada afirmación con nivel de certeza

| Nivel | Cómo lo expresas | Ejemplo |
|-------|------------------|---------|
| **Hecho** | "El estado registra…" | movimiento importado, saldo de corte, límite de crédito |
| **Derivado** | "Calculado usando…" | cash flow, utilización, patrimonio a una fecha |
| **Inferido** | "Parece probable…" | suscripción probable, fuente de ingreso, gasto discrecional |
| **Supuesto** | "Asumiendo que…" | ingreso de Fer, metas, tolerancia al riesgo |

Nunca presentes una inferencia como hecho.

### 3. Trazabilidad (`_shared/trace.py`)

Cada número que reportes se respalda con los `Transaction.id` (o merchantNormalized)
que lo produjeron. Si dices "subiste 23% en comida", lista los ids. Si el usuario pide
el detalle de un agregado, `_shared/trace.py` lo desglosa a las filas.

### 4. Solo lectura, salvo reclasificación aprobada

Nunca modifiques datos sin aprobación explícita del usuario. La única escritura es
reclasificar transacciones (`recategorize/`), y solo después de que el usuario apruebe
cada cambio. Esa sub-skill llama `_shared/writeback.py` para generar un `.ftbackup`
modificado que el usuario restaura manualmente en la app.

### 5. Privacidad

Todo corre local. El `.ftbackup` contiene tus movimientos reales sin redactar. No lo
envíes a ningún servicio externo — solo existe en tu sesión local de Claude.

## Cómo empezar

Toda sub-skill usa `_shared/load.py` para cargar el `.ftbackup` más reciente:

```bash
python3 .claude/skills/finanzas/_shared/load.py
```

Devuelve un resumen (cuentas, saldos, conteos) y deja los JSON cargables para el
`aggregate.py` de la sub-skill. Si el usuario indica un bundle específico, pásalo como arg.

## Referencias canónicas (no modificar; solo consultar)

- `FinanceTracker/Features/Backup/BackupModels.swift` — forma exacta del JSON.
- `FinanceTracker/Domain/Services/TransactionClassifier.swift` — los gates a replicar.
- `FinanceTracker/Domain/ValueObjects/` — rawValues de enums.
- `FinanceTracker/Features/Backup/BackupArchive.swift:390-409` — restore (write-back).
