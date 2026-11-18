# Recipe numbers come only from a measuring run or a person, never from a model

A recipe's memory footprint decides whether a model fits a host and which context `use --ctx` allows, so a wrong number loads a model that does not fit. Variants therefore carry a `source` (`measured`, `estimated`, `drafted`): only the engine writes `measured`, a person may type `estimated` and confirm it once, and `drafted` never counts as fitting. An agent that helps write a recipe (see #18, #23) drafts descriptive fields only; startdgx itself makes no model calls and the agent works through CLI steps.

Considered: letting the model estimate footprints from the repo's file sizes. Rejected, as Hugging Face metadata says neither the quant format nor the real peak reliably.

## Amended 2026-11-18: Add on a TensorFold entry is the person's say-so

The user decided a model they add should not need a measuring run first. A TensorFold list entry's memory figure is a third party's published estimate, not a model's guess from file sizes, so it can stand as `estimated`: **Add** writes the variant `estimated` from that figure and confirms it in the same action (`recipe confirm`), which counts as the person's confirmation, so the machine treats the model as fitting and **Set up…** works at once. **Measure…** stays, optional, and replaces the estimate with real numbers.

Unchanged: an entry with no estimate stays `drafted` (nothing to stand on), and every Hugging Face add stays `drafted` and needs a measuring run, since all it has is file sizes, the basis rejected above. `recipe draft` and `tensorfold draft` still write `drafted` unless the caller passes `--estimated`; only the panel's Add does.

Accepted risk: a wrong estimate can set up a model that doesn't fit. The engine still checks the free memory when it starts a model, which stops a load that cannot fit.
