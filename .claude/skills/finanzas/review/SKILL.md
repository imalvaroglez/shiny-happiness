---
name: finanzas-review
description: Sub-skill de informe del cerebro financiero. Orquesta hábitos, deuda, patrimonio e ingresos en una revisión de período estructurada con niveles de certeza. No cargar directamente; el router finanzas/SKILL.md despacha aquí cuando se pide "un informe" o "revisión del mes".
---

# /finanzas informe — revisión de período

Produce un informe integrado: qué cambió, qué impulsó el gasto, estabilidad de ingresos,
ahorro efectivo, presión de deuda, motores del patrimonio. **Cada afirmación etiquetada**
con nivel de certeza (Hecho/Derivado/Inferido/Supuesto).

## Cómo trabajar

1. `_shared/load.py`.
2. Ejecuta `scripts/report.py` — ya orquesta las 4 sub-skills y devuelve un dict estructurado.
3. Presenta el informe en lenguaje natural, respetando las etiquetas de certeza de cada bloque.
4. **Lead con la cobertura temporal**: cuándo empiezan y terminan los datos, y qué mes está
   posiblemente incompleto. Sin esto, los números engañan.

## Estructura del informe

```
📦 Datos: rango temporal, # transacciones, última fecha, (caveat: mes X posiblemente incompleto)

💰 Patrimonio (Derivado, punto en el tiempo)
   - Net worth / available net worth
   - Composición (liquidez/patrimonial/retiro/pasivo)
   - CAGR o crecimiento absoluto

📈 Ingresos (Hecho→Derivado)
   - Fuentes (concentración en salario = riesgo, Supuesto)
   - Savings rate por mes (con caveat de mes incompleto)

📉 Gasto / hábitos (Hecho→Derivado, recurrentes Inferido)
   - Top comercios
   - Deltas MoM
   - Suscripciones/recurrentes detectadas (Inferido)

💳 Deuda (Hecho saldos; Supuesto proyecciones)
   - Saldos y utilización por tarjeta
   - Pago-para-no-generar-intereses
   - Orden de ataque sugerido

🚩 Banderas
   - Cualquier número con caveat de cobertura
   - Utilización > 30%, concentración de ingreso > 80%, runway < 6 meses
```

## Regla de certeza aplicada al informe

Cada sección lleva su etiqueta en el encabezado. Las proyecciones (avalancha, runway, CAGR)
son **Supuesto**. Las detecciones (recurrentes) son **Inferido**. Los saldos importados son
**Hecho**. Los cálculos sobre hechos son **Derivado**. Si dudas, degrada a Inferido o Supuesto.
