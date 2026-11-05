# Idea pendiente: pasada de refinamiento visual del dashboard (inspiración BoardUI)

- **Fecha:** 2026-11-04
- **Estado:** idea registrada por el dueño; sin spec, sin plan — no es trabajo activo
- **Referencia:** https://www.boardui.com/components/finance-dashboard (template
  React/Next.js **Pro de pago**, web — **no se instala ni se copia código**;
  es inspiración de diseño para SwiftUI nativo)

## Qué tiene el template y a qué mapearía en FinanceTracker

| Componente BoardUI | Contraparte actual / trabajo |
|---|---|
| Balance KPI cards | Financial Snapshot (héroe + tiles) — ya en evolución con el spec "En cuentas ahora" (`2026-11-03-cash-on-hand-hero-design.md`) |
| Cash-flow Sankey full-width (ingresos → gasto) | Existe Sankey solo en propiedades; un Sankey de flujo consolidado (ingresos por fuente → categorías) sería nuevo |
| Spending-by-category rings | La dona actual es de composición de patrimonio; rings por categoría de gasto sería un upgrade de "Spending by Category" |
| Portfolio risk vs. return bubbles | Nuevo — requiere datos de mercado que hoy no se guardan (riesgo/rendimiento por posición; `StockPosition` no los tiene) |
| Daily spending heatmap | Nuevo — heatmap calendario de gasto diario |
| Transactions data table | `TransactionsView` ya existe |

## Nota

El objetivo declarado del dueño: "estaría padre tener algo así de refinado y
bonito" en la app nativa. Cuando se priorice, esto pasa por brainstorming →
spec → plan como cualquier feature; los candidatos naturales a primera
iteración son el Sankey de flujo consolidado y el heatmap diario (datos ya
disponibles), mientras los bubbles requieren fuentes de datos nuevas.
