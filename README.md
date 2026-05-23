# SQL Server Definition Manager

Manage SQL Server DDL definitions using Docker, Docker Compose, PowerShell and dbatools.

## Workflow

### Development Cycle

1. **Export** current definitions from the database:
   ```bash
   docker compose run --rm db export
   ```
   Cleans the `sql/` folder and downloads all DDL from the server.

2. **Modify** stored procedures, functions, or views in `sql/` as needed.

3. **Sync** your changes back to the database:
   ```bash
   docker compose run --rm db sync
   ```
   Uses staged changes (`git diff --cached`) to detect modifications. Prompts for confirmation before applying.
   - Stored procedures, functions, views → `DROP` + `CREATE OR ALTER`
   - Tables → not synced via this command (use execute with ALTER scripts instead)

### Temporary Work (temp/ folder)

Use `temp/` for scripts that are executed once and not tracked in `sql/`:
- Migration scripts
- Data fixes
- Ad-hoc ALTER TABLE scripts
- Test scripts

Execute any `.sql` file from `temp/`:
```bash
docker compose run --rm db execute ./temp/migration.sql
```
Prompts for confirmation before running.

### SSH Tunnel

```bash
docker compose up -d ssh-tunnel
```

Required when connecting through a bastion host or VPC.

## Commands

| Command | Description | Confirmation |
|---------|-------------|--------------|
| `db export` | Download DDL from server (tables/views/procs/functions) | No |
| `db sync` | Upload file changes (`git diff HEAD`) | Yes |
| `db sync <file>` | Upload specific file | Yes |
| `db execute <path>` | Execute custom SQL script | Yes |
| `db clean` | Delete all SQL files | No |

Use `-Force` to skip confirmation prompts.

## Output Structure

```
sql/
├── tables/
├── views/
├── storedprocedures/
└── functions/

temp/
└── (temporary scripts)
```

## Configuration

Copy `.env.example` to `.env` and set:

- `SQL_HOST`, `SQL_PORT`, `SQL_USER`, `SQL_PASSWORD`
- `SQL_DATABASE`, `SQL_TRUST_CERT=true`
- `SSH_KEY_PATH`, `SSH_USER`, `SSH_HOST`, `SSH_PORT` (for tunnel)