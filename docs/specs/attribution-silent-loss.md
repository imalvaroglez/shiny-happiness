# Fix: la hoja de detalle borra atribuciones a propiedad en silencio

- **Fecha:** 2026-11-04
- **Tipo:** bugfix (producción, datos del dueño)
- **Evidencia del incidente:** 2026-11-03 19:20:27, el cargo "Mercado Libre -
  Comida para Arette" (−$1,634, atribuido a Villas de la Hacienda el 2026-11-02
  20:27) perdió su atribución (`deletedAt`) al guardar una edición del cargo
  desde `TransactionDetailSheet`; el cargo desapareció del workspace de la
  propiedad sin aviso. Patrón recurrente reportado por el dueño.

## Comportamiento actual (defecto)

`TransactionDetailSheet.savePropertyAssociation`
(`Features/Transactions/TransactionDetailSheet.swift:939-948`): al guardar, si
el selector de propiedad del draft está vacío (`draftPropertyID == nil`), se
des-activa (`deletedAt = .now`) cualquier atribución activa existente — sin
confirmación y sin distinguir si el vacío fue una decisión del usuario o un
accidente de carga.

El selector puede quedar vacío sin decisión del usuario cuando
`loadPropertyDraft()` falla al leer el ledger (el `catch` solo setea
`propertySaveError`; el draft nunca se puebla) o cuando la hoja se guarda antes
de que la carga termine. En ese estado, guardar cualquier edición menor
(recategorizar, tratamiento) destruye la atribución.

## Comportamiento deseado

- Des-activar la atribución **solo** cuando el vacío del selector es una
  decisión conocida: el draft cargó correctamente (lectura del ledger exitosa
  al abrir) y el usuario dejó el selector en "Ninguna" — ya sea porque eligió
  "Ninguna" o porque movió el movimiento al hogar (comportamiento existente:
  propiedad y hogar son excluyentes).
- Si el estado del draft **no cargó** (lectura fallida o prematura), el
  selector vacío significa "desconocido", nunca "quitar": guardar NO toca la
  atribución. La edición del resto de campos del movimiento se guarda con
  normalidad.

## No-goals

- Cambiar la exclusión propiedad↔hogar ni los `onChange` cruzados.
- Cambiar `ManualTransactionSheet.persistPropertyAttribution` (creación:
  borra-y-recrea por diseño).
- Añadir confirmación UI para la remoción explícita (el selector es la
  confirmación).
- Restaurar automáticamente la atribución perdida del incidente (el dueño la
  re-atribuye manualmente desde la app).

## Implementación

1. Función pura `PropertyAssignmentService.shouldDeactivateAttribution(
   draftPropertyID:draftStateLoaded:hasActiveAttribution:)` — decisión
   testeable sin UI.
2. `TransactionDetailSheet`: bandera `propertyDraftStateLoaded` (false al
   iniciar `loadPropertyDraft()`, true tras una lectura exitosa con o sin
   atribución activa); la rama de borrado en `savePropertyAssociation` exige
   la decisión del helper.

## Pruebas (suite existente `PropertyAssignmentTests`)

1. Draft no cargado + atribución activa → **no** des-activa (el bug).
2. Draft cargado + selector vacío + atribución activa → des-activa (remoción
   explícita, comportamiento conservado).
3. Sin atribución activa, o con propiedad seleccionada → no des-activa.

Verificación §8 de LOOPS: build Debug + suite serial completa + money guard +
`git diff --check`. Sin UI harness: la validación del flujo en la hoja es
manual (dueño).

## Rollback

Sin cambios de esquema ni persistidos (el fix solo evita escrituras);
rollback = revert del commit, sin riesgo de datos.
