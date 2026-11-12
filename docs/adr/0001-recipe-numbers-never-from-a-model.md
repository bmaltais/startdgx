# Recipe numbers come only from a measuring run or a person, never from a model

A recipe's memory footprint decides whether a model fits a host and which context `use --ctx` allows, so a wrong number loads a model that does not fit. Variants therefore carry a `source` (`measured`, `estimated`, `drafted`): only the engine writes `measured`, a person may type `estimated` and confirm it once, and `drafted` never counts as fitting. An agent that helps write a recipe (see #18, #23) drafts descriptive fields only; startdgx itself makes no model calls and the agent works through CLI steps.

Considered: letting the model estimate footprints from the repo's file sizes. Rejected, as Hugging Face metadata says neither the quant format nor the real peak reliably.
