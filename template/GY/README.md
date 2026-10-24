# N4ti Project Memory

This directory is the repository's persistent operational memory.

- `core.md`: short rules and boundaries loaded every time.
- `current-state.md`: current task, verified result, risks, and next action.
- `commands.md`: commands known to work.
- `tasks/`: active and recently completed work.
- `decisions/`: durable choices and their consequences.
- `knowledge/`: architecture and domain information loaded on demand.
- `archive/`: historical evidence at level L4.
- `catalog.json`: machine-readable retrieval metadata.
- `checkpoints/`: manual, immutable progress snapshots; reported evidence, not verified results.
- `.runtime/`: generated context packs; never commit it.

Use `..\n4ti.cmd help` for commands (`gy.cmd` remains an alias). Do not store credentials or personal data here.

`save -Summary "progress" -Next "next step"` records only supplied text and metadata.
Add `-Id TASK-001` for a task checkpoint. `resume` prints the latest checkpoint;
`resume -Id TASK-001` filters by task. Resume is read-only and respects the estimated
context budget. Checkpoints do not change current-state, execute tests, read source
files, or automatically capture conversations. Each save is published atomically
as one JSON file; this is not a transaction over other memory files.
