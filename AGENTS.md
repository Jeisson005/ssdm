# SQL Server Definition Manager

## Overview

SSDM manages SQL Server DDL definitions using Docker, PowerShell, and dbatools. It tracks the state of database objects (stored procedures, views, functions, tables) and maintains versioned migrations for structural alterations.

## Directory Responsibilities

| Directory | Purpose | Versioned in Git? |
|-----------|---------|:-----------------:|
| `sql/` | Declarative object definitions (`views/`, `storedprocedures/`, `functions/`, `tables/`) | Yes |
| `migrations/` | **All structural `ALTER` scripts**, schema alterations, new table additions, and DDL migrations | **Yes** |
| `temp/` | Disposable scripts: read queries, test scripts, ad-hoc data updates/fixes (DML) | **No** (ignored) |

> [!IMPORTANT]
> **RULE FOR AI / DEVELOPERS:**
> - All scripts containing `ALTER TABLE` statements, schema modifications, or structural DDL changes **MUST** be saved in `migrations/` (e.g., `migrations/20261030_01_add_customer_column.sql`).
> - The `temp/` directory is **strictly for temporary queries or ad-hoc data updates** (unless the user explicitly requests storing a data update migration in `migrations/`).

## Commands

| Command | Use for | Syncs to DB? |
|---------|---------|:------------:|
| `db export` | Download DDL from server to `sql/` | No |
| `db sync` | Push staged changes (`git diff --cached HEAD`) with object pre-validation | Yes |
| `db sync <object>` | Push single object (e.g., `db sync dbo.sp_GetUsers` or `sp_GetUsers`) | Yes |
| `db sync <file>` | Push specific file (e.g., `db sync sql/views/dbo.v_Report.sql`) | Yes |
| `db sync <group>` | Push group (`views`, `storedprocedures`, `functions`, or `--all`) | Yes |
| `db sync <pattern>` | Push by wildcard pattern (e.g., `db sync 'sp_user*'`) | Yes |
| `db execute <path>` | Run SQL script (from `migrations/` or `temp/`) with pre-validation | Yes |
| `db clean` | Delete all SQL files in `sql/` | No |

Use `--force` or `-f` to skip confirmation prompts.

## Workflows

### 1. Modifying Stored Procedures, Views, or Functions:
1. Edit or create the file in `sql/storedprocedures/`, `sql/views/`, or `sql/functions/`.
2. Sync to the database:
   - **Option A (via Git stage):**
     `git add <file>` and then `docker compose run --rm db sync`
   - **Option B (single object):**
     `docker compose run --rm db sync dbo.MyProcedure`
   - **Option C (group or pattern):**
     `docker compose run --rm db sync views` or `docker compose run --rm db sync 'sp_user*'`
3. The system automatically pre-validates the current state of the object in the DB (existence, modification date, collision alerts) before applying `CREATE OR ALTER`.

### 2. Structural Alterations / Tables (ALTER):
1. Create the migration script in `migrations/` using timestamp/sequence convention:
   `migrations/YYYYMMDD_HHMMSS_alter_table_name.sql`
2. Execute the migration:
   ```bash
   docker compose run --rm db execute ./migrations/YYYYMMDD_HHMMSS_alter_table_name.sql
   ```
   *(The script runs automated pre-validation against SQL Server checking table existence, current row count, and whether columns to add already exist).*
3. Update local table definitions:
   ```bash
   docker compose run --rm db export --force
   ```
4. Commit both the script in `migrations/` and the updated definition in `sql/tables/` to Git.

### 3. Disposable Queries or Temporary Data Updates:
1. Create a script in `temp/my_query.sql`.
2. Execute:
   ```bash
   docker compose run --rm db execute ./temp/my_query.sql
   ```
   *(Not tracked in Git).*

## Core Rules

1. **ALTER scripts go to `migrations/`:** Never place `ALTER TABLE` DDL scripts in `temp/`.
2. **Active pre-validation:** All sync and execute operations validate prior state in the DB before applying changes.
3. **Tables are not synced with `sync`:** `sync` blocks files from `sql/tables/`; tables are altered via scripts in `migrations/` using `execute`.
4. **SSH Tunnel:** If working through a bastion host: `docker compose up -d ssh-tunnel`.
5. **Image rebuild:** After updating files in `scripts/`, rebuild with: `docker compose build db`.
