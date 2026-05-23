# SQL Server Definition Manager

## Commands

| Command | Use for | Syncs to DB? |
|---------|---------|--------------|
| `db export` | Download DDL from server to `sql/` | No |
| `db sync` | Push changes (git diff HEAD) for SP/views/functions | Yes |
| `db sync <file>` | Push specific file | Yes |
| `db execute <path>` | Run custom SQL (ALTER TABLE, migrations) | Yes |
| `db clean` | Delete all SQL files | No |

Use `--force` to skip confirmation.

## Workflow

**SP, Views, Functions:**
1. Edit file in `sql/`
2. Stage changes: `git add <file>` or `git add .`
3. `docker compose run --rm db sync`

**Tables (ALTER):**
1. Create script in `temp/` (e.g., `ALTER TABLE ...`)
2. `docker compose run --rm db execute ./temp/script.sql`
3. `docker compose run --rm db export --force` (to sync local files with DB)

**New objects:**
1. Create `.sql` file in `sql/storedprocedures/`, `sql/views/`, or `sql/functions/`
2. Commit
3. `docker compose run --rm db sync <file>`

**Delete objects:**
1. Remove file from `sql/` and commit
2. `docker compose run --rm db sync`

## Rules

- Tables: use `execute` with ALTER scripts in `temp/`, NOT `sync`
- `sync` requires staged files (`git diff --cached HEAD`)
- SSH tunnel: `docker compose up -d ssh-tunnel`
- After script changes: `docker compose build db`