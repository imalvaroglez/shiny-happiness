# Trust import diagnostics

## Acceptance criteria

- **TR-IMP-01 — Row-level review details.** A pasted HSBC row that cannot be
  parsed is staged as `PendingImport` and appears in the import report with its
  one-based pasted-text row, reason, and original row text. Staging remains a
  successful partial import, not a failed import.
- **TR-IMP-02 — Unsupported paste guidance.** Unknown pasted text clearly says
  that paste import supports HSBC 2Now, recommends the `TU PAGO REQUERIDO`
  header for a complete import, and exposes a synthetic example through a
  semantic `Button`.

## Accessibility validation

There is no UI-test target. During development validation, use keyboard focus
to open **Review details** and **Show HSBC 2Now example**, then use VoiceOver
to confirm both controls announce their labels and hints. Confirm the error
sheet announces a row number, message, and detail for a staged row.

## Non-goals

- Add no new supported paste issuer.
- Do not expose personal statement text in fixtures or examples.
- Do not change the persisted schema or `PendingImport` resolution workflow.
