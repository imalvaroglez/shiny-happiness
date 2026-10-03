# Correcciones de la cadena #27–#30

Plan aprobado por el dueño en esta conversación. Objetivo: corregir persistencia,
semántica y casos límite antes de la validación de desarrollo. Sin release,
instalación ni acceso al store de producción. Modelos SwiftData congelados.

## Contratos

- Edición de promociones conserva meta y límites independientes; una entrada
  inválida no se convierte en ausencia de meta. Ventanas invertidas se rechazan.
- Mutaciones nuevas usan `updatedAt` estrictamente creciente por entidad a
  precisión de segundos. Replace/merge preservan timestamps del archivo. Empates
  históricos con distinto contenido conservan local y producen advertencia.
- Restore valida antes de mutar; usa un contexto dedicado sin autosave y JSONs
  staged. Falla antes del commit: rollback de modelos, originales JSON byte por
  byte y retirada de statements nuevos. Compensación fallida: error visible y
  copias recuperables conservadas. No descarta borradores del contexto llamador.
- Notificaciones de sidecars solo después del commit completo; las lecturas de
  transacciones fallidas se muestran como indisponibilidad, nunca como cero.
- Identidad seed no depende del nombre visible. Renombrar sueldo/intereses no
  altera importes financieros; aliases originales sobreviven reinicios, reglas
  nuevas y renombres posteriores. Personalización corrupta no se sustituye por
  un catálogo vacío durante bootstrap.
- La fecha manual sigue la última captura exitosa por cuenta. Ediciones,
  cancelaciones y fallos previos al save no la cambian. No se reconstruye orden
  de creación desde `lastModifiedAt`; sin preferencia se usa hoy.
- Header y filas comparten anchuras, incluido badge vacío; títulos de una línea
  respetan el tamaño de texto solicitado.

## Verificación

Tests de regresión con fixtures sintéticos, contenedores en memoria y stores en
disco temporales. Fallos inyectados después de publicación de archivos y antes
del save; reabrir disco demuestra preservación. Suite serial completa y pytest
completo al integrar. Evidencia de rendimiento y limitaciones se registran en el
handoff; pruebas funcionales no prueban respuesta visual menor a 100 ms.

La revisión independiente adicional sigue pendiente si no hay herramienta de
subagentes. No declarar READY FOR DEVELOPMENT VALIDATION sin cumplir LOOPS §8–9.
