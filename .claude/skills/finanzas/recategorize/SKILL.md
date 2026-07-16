---
name: finanzas-recategorize
description: Sub-skill de reclasificación del cerebro financiero. Detecta transacciones mal categorizadas, propone correcciones, y (solo tras aprobación explícita) genera un .ftbackup modificado para restaurar en la app. No cargar directamente; el router finanzas/SKILL.md despacha aquí.
---

# /finanzas reclasificar — corregir categorías

El lazo de escritura. Detecta transacciones mal categorizadas, propone cambios, y —solo
después de que el usuario apruebe cada uno— genera un `.ftbackup` que el usuario restaura
manualmente en la app (Settings → Restore).

**Alcance estricto**: solo `categoryId` / `flowKindRaw` / `treatmentKindRaw` / `movementKindRaw`.
No crea `CategoryRule`, no soft-deleta, no toca montos/fechas/duplicados.

## Flujo OBLIGATORIO (nunca saltarse)

1. **Detectar** candidatos con `scripts/detect.py` (heurística, presenta como Inferido).
2. **Mostrar** cada candidato al usuario con evidencia (merchant, descripción, categoría actual vs propuesta).
3. **Esperar aprobación explícita** por cada cambio. Nunca escribir sin ella.
4. Solo con los cambios aprobados, llamar `_shared/writeback.apply_recategorizations()`.
5. **Indicar al usuario** la ruta del `.ftbackup` generado y cómo restaurarlo.
6. Recordar: tras restaurar, re-exportar un backup para que el `.ftbackup` source del skill se actualice.

## Detección (`scripts/detect.py`)

```python
import sys, os; sys.path.insert(0, os.path.abspath('_shared')); sys.path.insert(0, os.path.abspath('recategorize/scripts'))
from load import load_dataset, live_transactions
import detect
ds = load_dataset(); txs = live_transactions(ds)
detect.merchant_category_mismatch(txs, ds)   # merchant conocido en otra categoría
detect.uncategorized_with_known_merchant(txs, ds)  # sin categoría pero merchant reconocible
```

## Reglas específicas

- **Toda propuesta es Inferido**: "parece que esto debería ser X". La decisión final es del usuario.
- **Validación de writeback**: `writeback.apply_recategorizations` valida que el `categoryId`
  destino exista en `Category.json`, que los `*Raw` sean válidos, y bumpa `lastModifiedAt`.
  Si algo falla, aborta sin escribir.
- **No tocar el bundle source**: se genera un bundle NUEVO (copia del actual + cambios).
  El usuario decide restaurarlo o no.
- **Categorías soft-deleted**: no proponer mover a una categoría con `deletedAt != nil`.
- **Una transacción a la vez visible**: muestra evidencia concreta (id, merchant, monto, fecha,
  categoría actual, categoría propuesta, por qué) para cada cambio que pides aprobar.
