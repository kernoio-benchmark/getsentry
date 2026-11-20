# flag-cleanup — retire one FlagPole flag

A HAR factory line. One run retires one fully rolled-out flag, in the order
from the `remove-option-or-flag` skill. Its gate stages are registered in
`.har/stages.json` but are **not** on `har env verify` — they run only through
`har line gate`.

## Stations

| Station                    | PR             | What happens                                                                                                                                       | Gate adds                                |
| -------------------------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| S0 Preconditions           | —              | Confirm the flag is temporary, list every read, record the automator value on the ticket. Stop and ask on drift / split regions / getsentry reads. | `flag-cleanup-not-permanent`             |
| S1 Collapse backend reads  | 1a             | `src/` + `tests/`: keep the winning branch, delete the losing one.                                                                                 | `flag-cleanup-reads-backend`, `pr-split` |
| S2 Collapse frontend reads | 1b             | `static/` only, after 1a merged.                                                                                                                   | `flag-cleanup-reads-frontend`            |
| S3 Automator block         | 2 (other repo) | `sentry-options-automator`, after 1a + 1b are **deployed**. Human-run.                                                                             | — (re-runs everything above)             |
| S4 Remove the registration | 3              | `temporary.py`, after S3 deployed and green.                                                                                                       | `flag-cleanup-registration-absent`       |

The gate is cumulative. S2 re-checks backend reads, so running S2 before
PR 1a has landed fails, which keeps the removal order. The gate can't see
deploys, so the Linear ticket (the traveler) records them.

## Running it

```bash
har env launch 3 --work-id <TICKET> --work-source linear
# … the agent edits in the slot work dir, har env verify 3 --full …
HAR_FLAG=organizations:my-feature har line gate S1 --line flag-cleanup --agent 3
```

`HAR_FLAG` is required: the full flag name with its scope prefix. Reports land
in `.har/artifacts/flag-cleanup-*/agent-<id>.txt` and run records in `.har/runs/`.

## Stage files

`stages/flag-cleanup-lib.sh` holds all the checks. The four
`flag-cleanup-<check>.sh` wrappers are what `.har/stages.json` registers.
`pr-split` is a repo stage (`.har/stages/pr-split.sh`), shared with
`flagged-feature`. After editing anything here, re-run
`har line add flag-cleanup --force` so the copies in `.har/stages/` are updated.

## Known limits

- `har line status` reads the latest run record per stage. It doesn't know
  which `HAR_FLAG` produced a run, so with two cleanups in flight its
  per-station view mixes them. Use the run reports.
- `reads-frontend` matches any quoted occurrence of the short name in
  `static/`. A generic name can match unrelated strings.
- getsentry is not in this repo. S0 has to ask whether getsentry reads the flag.
