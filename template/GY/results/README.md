# Agent Results

Subagents return concise structured evidence here or through the orchestrator.
They must not update canonical GY state directly.

Each result should identify task, role, status, changed files, tests, risks,
proposed decisions, and a summary. `record-result` rejects a whole result above
`resultTokenCap` in `policies/orchestration.json` (default 800 estimated tokens).
