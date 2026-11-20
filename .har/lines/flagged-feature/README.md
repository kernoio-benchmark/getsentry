# flagged-feature — ship one feature dark, behind a FlagPole flag

A HAR factory line. One run takes a feature from contract to a proven, still-dark
feature as separately deployable PRs, with the backend landing before the
frontend that depends on it. Its gate stages are registered in
`.har/stages.json` but are **not** on `har env verify` — they run only through
`har line gate`.

## Stations

| Station                | PR        | What happens                                                                                          | Gate adds                                                                              |
| ---------------------- | --------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| S1 Contract            | —         | Flag name, models + silo, endpoint shapes, UI entry point on the ticket. A human approves it.         | —                                                                                      |
| S2 Flag + data model   | backend 1 | Register the flag (default off), add the model and migration, apply it to the slot DB.                | `flagged-feature-flag-registered`, `flagged-feature-migrations-consistent`, `pr-split` |
| S3 API behind the flag | backend 2 | Endpoints gated with `features.has`, tests with the flag on and off, reviewed with `sentry-security`. | `flagged-feature-backend-gated`                                                        |
| S4 UI behind the flag  | frontend  | `static/` only, after the backend PRs are **deployed**. Specs render with the flag on.                | `flagged-feature-frontend-gated`                                                       |
| S5 Prove in a slot     | —         | Enable the flag in the slot and drive the feature with `verify-sentry`. Evidence goes on the ticket.  | — (re-runs everything above)                                                           |

`pr-split` runs from S2 onward, so every station's slot holds exactly one
deployable PR. Rollout in `sentry-options-automator` is out of scope.

## Running it

```bash
har env launch 3 --work-id <TICKET> --work-source linear
# … the agent edits in the slot work dir, har env verify 3 --full …
HAR_FLAG=organizations:my-feature har line gate S3 --line flagged-feature --agent 3
```

`HAR_FLAG` is required for every check except `migrations-consistent`, which
runs CI's `makemigrations --check --dry-run` against the slot (~20 s). Reports
land in `.har/artifacts/flagged-feature-*/agent-<id>.txt`.

## Stage files

`stages/flagged-feature-lib.sh` holds all the checks. The
`flagged-feature-<check>.sh` wrappers are what `.har/stages.json` registers.
After editing, re-run `har line add flagged-feature --force`.

## Known limits

- S5 has no stage yet. When a proof finds a class of defect, add a stage that
  checks for it and tag it `fromStation: S5`.
- `backend-gated` only checks that `src/` reads the flag and that some test
  names it. It can't tell whether _every_ new path is gated. Review covers that.
- `har line status` doesn't know which `HAR_FLAG` produced a run (see the
  flag-cleanup README).
