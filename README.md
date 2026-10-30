# SQL Server Definition Manager

Manage SQL Server DDL definitions using Docker, Docker Compose, PowerShell, and dbatools across multiple environments (dev, qa, prod).

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
├── db                  # Executable CLI wrapper with multi-environment support
├── docker-compose.yml
└── Dockerfile
```

---

## Multiple Environments Support

SSDM supports managing multiple environments (e.g. `dev`, `qa`, `staging`, `prod`) with independent database credentials and SSH tunnel parameters.

### 1. Setting up environments

Copy `.env.example` to create environment-specific files:

```bash
cp .env.example .env.dev
cp .env.example .env.qa
cp .env.example .env.prod
```

Configure `SQL_HOST`, `SQL_DATABASE`, `SQL_USER`, `SQL_PASSWORD`, and SSH settings in each file.
All `.env*` files are ignored in `.gitignore` (except `.env.example`), keeping credentials safe from commits.

### 2. Targeting an environment

Use the `./db` CLI wrapper with `--env <name>` or `-e <name>`:

```bash
# Sync staged files to QA
./db --env qa sync

# Sync specific procedure to Production
./db --env prod sync dbo.sp_GetUsers

# Execute a migration in Development
./db --env dev execute ./migrations/20261030_01_add_column.sql

# Start SSH tunnel for production
./db --env prod tunnel

# Stop tunnel
./db --env prod down
```

Whenever a command is executed, SSDM prints a banner confirming the active file and target database:
```
[SSDM] Target: .env.prod (DB: db_SmartMapsFT_Prod)
```

Alternatively, you can run directly with Docker Compose:
```bash
ENV_FILE=.env.prod docker compose --env-file .env.prod run --rm db sync
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

## Commands Reference

| Command | Description | Affects DB? |
|---------|-------------|:-----------:|
| `./db export` | Download DDL from server to `sql/` folder (cleans first) | No |
| `./db sync` | Sync staged files (`git diff --cached HEAD`) with pre-validation | **Yes** |
| `./db sync <object>` | Sync single object (e.g. `dbo.sp_GetUsers` or `sp_GetUsers`) | **Yes** |
| `./db sync <file>` | Sync specific file (e.g. `sql/views/dbo.v_Report.sql`) | **Yes** |
| `./db sync <group>` | Sync an entire group (`views`, `storedprocedures`, `functions`, `--all`) | **Yes** |
| `./db sync <pattern>` | Sync objects matching wildcard pattern (e.g. `'sp_user*'`) | **Yes** |
| `./db execute <path>` | Execute SQL script (from `migrations/` or `temp/`) with pre-validation | **Yes** |
| `./db tunnel` | Start SSH tunnel container for bastion host/VPC | No |
| `./db down` | Stop SSH tunnel or background compose containers | No |
| `./db clean` | Delete all SQL files in `sql/` | No |

Add `--force` or `-f` to bypass confirmation prompts.
Add `--env <name>` or `-e <name>` to select environment (defaults to `.env`).

---

## Workflow Examples

### 1. Stored Procedures, Views, and Functions

**Option A: Using Git Staging**
```bash
# 1. Edit file in sql/storedprocedures/dbo.sp_MyProc.sql
git add sql/storedprocedures/dbo.sp_MyProc.sql
./db sync
# Or target prod:
./db --env prod sync
```

**Option B: Syncing a Single Object directly**
```bash
./db sync dbo.sp_MyProc
```

**Option C: Syncing a Group or Pattern**
```bash
# Sync all views
./db sync views

# Sync all stored procedures matching pattern
./db sync 'sp_user*'

# Sync multiple objects
./db sync dbo.sp1 dbo.sp2
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
   ./db execute ./migrations/20261030_01_add_status_to_customers.sql

   # To apply to another environment:
   ./db --env prod execute ./migrations/20261030_01_add_status_to_customers.sql
   ```

3. Export updated table definitions to refresh `sql/tables/`:
   ```bash
   ./db export --force
   ```

4. Commit both the migration script and the updated table definition to Git.

---

### 3. Disposable Queries & Temporary Data Fixes

Use `temp/` for one-off scripts:
```bash
./db execute ./temp/check_data.sql
```

---

## Configuration Reference

Each `.env.<env>` file can define:
- `SQL_HOST`, `SQL_PORT`, `SQL_USER`, `SQL_PASSWORD`
- `SQL_DATABASE`, `SQL_TRUST_CERT=true`
- `SSH_KEY_PATH`, `SSH_USER`, `SSH_HOST`, `SSH_PORT` (for SSH bastion tunnel)
- `SSH_REMOTE_HOST`, `SSH_REMOTE_PORT`, `SSH_LOCAL_PORT`
