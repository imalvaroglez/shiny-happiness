# Guías de interfaz

Esta guía codifica el lenguaje existente de la app; no introduce otra familia visual.

## Tokens y superficies

Reutilizar `DashboardCardTokens`: `sectionSpacing = 16`, `topStackSpacing = 20`,
`compactPadding = 14`, `heroPadding = 18`, `innerWellRadius = 8`, `plotStrokeRadius = 6`.
La línea visual de toda la app es Liquid Glass, como en Cuentas. Las pantallas heredan
el `AppBackdrop` compartido y las superficies reutilizan `GlassCard` y materiales
nativos. No cubrir el fondo con capas blancas opacas. `GlassRadius`: card 12, hero 16,
sheet 20 y chip 999. Tablas y listas de Propiedades usan `PropertyTableCard`, que
reutiliza `GlassCard` con relleno compacto 14 y mantiene los encabezados al exterior.
Comprobar contraste, apariencias clara/oscura y opciones de accesibilidad cuando haya
disponibilidad de pantalla. Esta regla sustituye el anterior fondo opaco de tablas.

## Encabezados, filas y tablas

`PropertySectionHeading` es el patrón de título (`headline`) y acción (`link`,
`caption`). El encabezado permanece fuera del relleno de la card, sobre el mismo
margen del resto de las secciones. Evitar títulos y botones sueltos equivalentes.

Cada tabla define un layout común a encabezados y filas, como `TransactionLedgerLayout`.
La columna de concepto/nombre es flexible; las columnas monetarias se alinean a la
derecha con `monospacedDigit()`. El encabezado usa `caption2.weight(.medium)` secundario.
La tabla ocupa todo el ancho y no necesita desplazamiento horizontal. `ViewThatFits`
selecciona la variante compacta que conserva origen, responsabilidad e importes;
no ocultar información funcional ni comprimir controles hasta hacerlos inutilizables.
Las tablas con varias columnas de datos permiten ordenar desde cada encabezado y
alternar ascendente/descendente. La variante compacta ofrece el mismo orden en un
menú visible. Al ordenar por otra columna, fecha ascendente desempata antes del UUID;
los valores faltantes permanecen al final. Los filtros multiselección de columnas se
combinan con AND entre columnas y OR dentro de cada una. El título de una columna
filtrable es directamente el menú: reúne orden y filtro en un único control, con el
nombre completo en una línea. La variante compacta reutiliza ese mismo menú y apila
los encabezados cuando no caben. Los encabezados permanecen visibles sin resultados
para permitir retirar los filtros.

Acciones frecuentes visibles mediante `InlineRowAction`, con ayuda y etiqueta accesible. `PropertySectionHeading` acepta contenido `trailing` en la misma fila (p. ej. el selector de alcance); en anchos estrechos ese contenido cae a una segunda fila alineada al borde derecho.
Menús compactos para asignaciones; confirmaciones destructivas con `confirmationDialog`.
Cada integrante aparece una vez; ingreso, estado, confirmación y aportación permanecen próximos.
Las acciones de integrante son botones directos con nombre: Renombrar y Quitar.
Renombrar abre solo el nombre; Quitar abre directamente la confirmación de vigencia.
No añadir campos de notas ni menús intermedios a estas acciones.

## Dinero, lenguaje y formularios

Usar `propertyMoneyText`/`MoneyFormat` con moneda explícita. La magnitud sin signo en la
actividad se acompaña del tipo Gasto o Reembolso: no modifica los signos contables.
Cero es un saldo real; datos insuficientes se indican como “Por calcular”.

Toda cadena de interfaz usa claves inglesas y traducción es-MX en `Localizable.strings`,
incluidos errores, interpolaciones, ayuda y accesibilidad. Los nombres y conceptos del
usuario son datos y no se traducen. Un concepto financiero tiene una sola clave: por
ejemplo, `Prior debt` para deuda anterior, sin aliases de “Saldo anterior”.

Formularios con título visible, etiquetas completas/multilínea y controles alineados.
`StandardEditorForm` ofrece Cancelar/Guardar y atajos nativos; un fallo conserva el borrador.

Los detalles muestran valores en modo consulta y ofrecen Editar; una acción explícita
de edición abre directamente los controles. Los importes sugeridos se muestran como
valores con Cambiar, sin enfocar automáticamente un campo. `EditableValueField` conserva
el borrador y el error cuando falla el guardado; Enter confirma y Escape restaura.
Las capturas nuevas, búsquedas, filtros y acciones explícitas de renombrar conservan
sus controles directos. La precisión de cantidades y porcentajes sigue sus propias reglas.

Los cobros se consultan desde la columna Pago de cada integrante. La tabla de movimientos
vinculados muestra gastos y reembolsos, y su subtotal excluye los cobros.

La cuenta del integrante es una tabla exacta que suma a mano: importes visibles con su operación, nota factual con importe y motivo en lugar de ocultar el saldo, y «Por calcular» o «Proyección» para lo que aún no es hecho. «Ver detalle» de una cifra abre la tabla de actividad filtrada por identidad de atribución —no por etiqueta— para que el subtotal verifique la cifra.

## Inventario y alcance

| Área | Patrón existente y regla |
| --- | --- |
| Categorías | Acciones inline de renombrar, color y eliminar; alta de subcategorías inline. |
| Cuentas | Grupo desplegable compartido con Propiedades; creación en Agregar y orden contextual. |
| Movimientos | `TransactionLedgerLayout`; conservar origen y semántica del movimiento real. |
| Propiedades | `PropertyMembersLayout`, `PropertyActivityLayout`, `PropertySectionHeading`, `PropertyTableCard`. |
| Promociones | Acciones contextuales y editor; conservar validaciones y borrador ante error. |
| Portafolio | Filas monetarias alineadas y edición contextual de posiciones. |
| Importación | Revisión de filas y mensajes recuperables; no convertir referencias en movimientos. |
| Configuración | Usar acciones inline para datos editables; evitar experiencias paralelas para la misma acción. |

El patrón se aplica a los detalles de movimientos, configuración de cuentas, posiciones,
revisión de importaciones y Propiedades. Los formularios que ya se abren desde una acción
explícita de edición permanecen en modo edición.

## Verificación no disruptiva

La prueba de layout o el primer dibujo no acreditan latencia visible. Capturas,
automatización de ventanas, cambios de apariencia y VoiceOver requieren disponibilidad
explícita de pantalla, conforme a `AGENTS.md` y `docs/LOOPS.md`. Mientras falten, registrar
el pendiente y no declarar preparación para validación.
