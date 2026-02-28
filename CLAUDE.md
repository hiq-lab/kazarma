# Kazarma — Claude Code Guidelines

## Session startup
Follow `~/Projects/valiant-ops/shared/session-startup.md` before starting any work.

## Project context
`~/Projects/valiant-ops/projects/kazarma/CONTEXT.md` — tech stack (Elixir/Phoenix), dev infra Docker, Matrix/ActivityPub bridge purpose.

## Build & run
```bash
mix deps.get
mix phx.server

# Dev infra (Matrix + ActivityPub test instances):
cd infra/dev && docker compose up -d
```

## Valiant Ops — Task board
- **Sync before work:** `cd ~/Projects/valiant-ops && git pull --rebase origin main`
- **Claim tasks:** Set `assignee` + `instance` in board.yaml, commit+push
- **Results:** Write to `results/{task-id}/summary.md`, update board.yaml status → done
