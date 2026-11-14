# StartDGX

Control DGX Spark hosts from an Omarchy desktop over SSH. A host runs an engine that sets up and serves models; this project is the CLI and the panel in front of it.

## Language

**Host**:
A DGX Spark machine reached over SSH that runs the engine and serves models.
_Avoid_: Server, box, node

**Engine**:
The software on a host that sets models up, starts them and shares them (our fork of omarchy-local-ai, pinned to a tag).
_Avoid_: Backend, daemon

**Recipe**:
A file that says how to fetch and run one model on a runtime, with its measured footprints.
_Avoid_: Config, profile, preset

**Curated recipe**:
A recipe that ships with the engine.
_Avoid_: Built-in, official

**User recipe**:
A recipe a person added to a host; it lives apart from the engine's own and never replaces a curated one.
_Avoid_: Custom recipe, local recipe

**Model store**:
A folder on an external disk of a host (ext4, xfs or btrfs, marked with `.startdgx-store`) that holds copies of models' weights, set per host with `storage --set`. A store without its marker counts as not mounted.
_Avoid_: Mirror, cache, USB folder

**Location**:
Where a model's weights are: `nvme` (the host's internal disk), `usb` (the store), `both`, `usb-missing` (on a store that isn't mounted) or `mixed` (filesets split). Moving a model changes it; moving to the store replaces the internal copy with a link, moving back keeps the store's copy.
_Avoid_: Tier, storage class

**Variant**:
One context size of a recipe with the memory it needs and where those numbers came from.
_Avoid_: Profile, size

**Source** (of a variant):
Where a variant's numbers came from: `measured` (a measuring run), `estimated` (typed by a person and confirmed once) or `drafted` (not yet known).
_Avoid_: Origin, provenance

**Measuring run**:
The engine loading a recipe at one context and recording its real peak memory and speed.
_Avoid_: Benchmark (unless speaking of the tool), test

**Fits**:
A variant fits a host when its memory, plus what the desktop needs, is available; only `measured` and confirmed `estimated` variants count.
_Avoid_: Compatible, supported

**Share**:
Making a model reachable by other Omarchy machines over the tailnet.
_Avoid_: Publish, expose

**Known family**:
A model architecture that TensorFold is known to serve on the GB10, from its README's checked checkpoints; search lists only repos of a known family.
_Avoid_: Supported architecture, compatible model

**Draft**:
The recipe file written for a Hugging Face repo before any measuring run; its variant numbers are placeholders marked `drafted`.
_Avoid_: Generated recipe, auto-recipe

**Authoring brief**:
The instructions an agent works from when it helps finish a draft: the recipe rules, the CLI steps it may use, and the limits on downloads and measuring runs.
_Avoid_: Prompt, system prompt
