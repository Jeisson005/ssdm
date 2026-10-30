# SQL Server Definition Manager

Manage SQL Server DDL definitions using Docker, Docker Compose, PowerShell, and dbatools.

## Architecture & Directory Structure

```
├── migrations/         # Versioned structural DDL migrations (ALTER TABLE, column changes, indexes)
├── sql/                # Declarative DDL snapshot of database objects
│   ├── tables/
│   ├── views/
│   ├── storedprocedures/
│   └── functions/
├── temp/               # Temporary, disposable scripts (queries, data updates/fixes, ignored in git)
├── scripts/            # Automation PowerShell scripts
├── docker-compose.yml
└── Dockerfile
```

---

## Directory Policies

- **`migrations/`**: Contains all structural alteration scripts (`ALTER TABLE`, new columns, indexes, schema changes). **Tracked and versioned in Git**.
- **`temp/`**: Reserved exclusively for read queries, tests, or ad-hoc data fixes/updates (DML). **Ignored in Git** (unless the user explicitly requests storing a data update migration in `migrations/`).
- **`sql/`**: Reflects the current declarative state (*snapshot*) of the database.

---

## Pre-Validation Workflow

Before applying any change to the database, the system performs an **automated pre-validation**:
- **On sync (`sync`):** Queries `sys.objects` to check whether the object exists, its type, creation date, and last modification date in the DB vs. the local file, warning if the object was modified more recently in the DB.
- **On executing alterations (`execute`):** Analyzes tables referenced in `ALTER`/`CREATE`/`DROP` scripts, checks if the table exists in the DB, reports current row count, and in case of `ALTER TABLE ... ADD [column]`, verifies whether the column already exists in `sys.columns` to prevent runtime failures.

---

## Commands

| Command | Description | Confirmation |
|---------|-------------|:------------:|
| `db export` | Download DDL from server to `sql/` folder (cleans first) | No |
| `db sync` | Sync staged files (`git diff --cached HEAD`) with pre-validation | Yes |
| `db sync <object>` | Sync single object (e.g. `dbo.sp_GetUsers` or `sp_GetUsers`) | Yes |
| `db sync <file>` | Sync specific file (e.g. `sql/views/dbo.v_Report.sql`) | Yes |
| `db sync <group>` | Sync an entire group (`views`, `storedprocedures`, `functions`, `--all`) | Yes |
| `db sync <pattern>` | Sync objects matching wildcard pattern (e.g. `'sp_user*'`) | Yes |
| `db execute <path>` | Execute SQL script (from `migrations/` or `temp/`) with pre-validation | Yes |
| `db clean` | Delete all SQL files in `sql/` | No |

Use `--force` or `-f` to bypass confirmation prompts.

---

## Workflow Examples

### 1. Stored Procedures, Views, and Functions

**Option A: Using Git Staging**
```bash
# 1. Edit file in sql/storedprocedures/dbo.sp_MyProc.sql
git add sql/storedprocedures/dbo.sp_MyProc.sql
docker compose run --rm db sync
```

**Option B: Syncing a Single Object directly**
```bash
docker compose run --rm db sync dbo.sp_MyProc
```

**Option C: Syncing a Group or Pattern**
```bash
# Sync all views
docker compose run --rm db sync views

# Sync all stored procedures matching pattern
docker compose run --rm db sync 'sp_user*'

# Sync multiple objects
docker compose run --rm db sync dbo.sp1 dbo.sp2
```

---

### 2. Table Modifications & Structural Migrations (ALTER)

1. Create a migration file in `migrations/` (recommended format: `YYYYMMDD_HHMMSS_description.sql`):
   ```sql
   -- migrations/20261030_01_add_status_to_customers.sql
   ALTER TABLE dbo.Customers ADD Status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE';
   ```

2. Execute the migration (runs pre-validation against the database first):
   ```bash
   docker compose run --rm db execute ./migrations/20261030_01_add_status_to_customers.sql
   ```

3. Export updated table definitions to refresh `sql/tables/`:
   ```bash
   docker compose run --rm db export --force
   ```

4. Commit both the migration script and the updated table definition to Git.

---

### 3. Disposable Queries & Temporary Data Fixes

Use `temp/` for one-off scripts:
```bash
docker compose run --rm db execute ./temp/check_data.sql
```

---

### 4. SSH Tunnel

```bash
docker compose up -d ssh-tunnel
```
Required when connecting through a bastion host or VPC.

---

## Configuration

Copy `.env.example` to `.env` and set:
- `SQL_HOST`, `SQL_PORT`, `SQL_USER`, `SQL_PASSWORD`
- `SQL_DATABASE`, `SQL_TRUST_CERT=true`
- `SSH_KEY_PATH`, `SSH_USER`, `SSH_HOST`, `SSH_PORT` (for tunnel)
