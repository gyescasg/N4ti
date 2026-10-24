# N4ti Specification (GY V2-compatible storage)

## Objective

Turn a product idea and an existing or new repository into a lightweight,
provider-neutral development workflow with selective memory, OpenSpec-aware
planning, dynamic specialist agents, model guidance, controlled autonomy, and
verifiable results.

## Product Boundary

N4ti is the current product name. Fresh installs use `N4ti/`; existing `GY/`
stores remain in place. Both command names share one implementation and store.
Ambiguous or malformed existing stores fail before mutation. No automatic folder
migration or merge is performed.

GY stores policy and project state in the repository. Codex or Claude remains the
execution host. GY does not require an API, does not silently deploy, and does not
claim that one technology or model is universally best.

## Initialization Contract

`gy.cmd init` must accept one required semantic input: the product idea. It scans
the repository deterministically, detects checkpoints and OpenSpec, records
technical signals, configures operating modes, and generates a bounded analysis
request for the orchestrator. The orchestrator then completes semantic fields and
asks only high-impact questions.

## Ownership

- OpenSpec owns product requirements and acceptance criteria when present.
- Git owns source history.
- GY owns current operational state, decisions, routing, and evidence.
- The orchestrator is the sole canonical writer to GY.
- Subagents own scoped implementation outputs, never shared memory.

## Modes

- Model routing: `uniform`, `adaptive`, or `manual`.
- Autonomy: `conservative`, `balanced`, or `autonomous-with-gates`.
- Initialization: `quick` or `guided`.

## Context Budgets

- Startup core and state: target below 1,500 tokens.
- Normal task packet: target 1,500-4,000 tokens.
- Subagent result: at most `resultTokenCap` (orchestration policy, default 800); `record-result` rejects larger results without writing.
- Archive: retrieved only for explicit historical evidence.

## Acceptance Criteria

- A fresh repository can be installed and initialized from one idea.
- An existing checkpoint is discovered and offered for migration.
- OpenSpec is detected without duplicating its content.
- Staff and model policy are generated with uniform-model support.
- Policies prevent subagents from racing on canonical memory.
- Production and merge remain approval-gated.
- Validation detects incomplete initialization and invalid paths.
- The complete smoke workflow runs without API access.

## Manual Progress Checkpoints

- `n4ti save` requires a summary and next step, optionally scoped to exactly one
  catalog task. It stores only supplied metadata as reported, unverified evidence.
- Each checkpoint is a unique JSON file published through a same-directory rename;
  task, catalog, and current-state files are not part of that write.
- `n4ti resume` reads the latest checkpoint, optionally filtered by task, and emits
  a bounded complete context without modifying any project files.
- No automatic conversation capture, credential detection, source-file reading,
  test execution, new runtime dependency, or external memory service is implied.
- Regression coverage includes fresh and legacy stores, alias equivalence,
  idempotent upgrades, invalid-store refusal, literal text, isolation and budgets.
