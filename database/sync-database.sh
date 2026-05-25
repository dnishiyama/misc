#!/bin/bash
#
# Database Sync Script
# Copies a PostgreSQL database from one environment to another
#
# Usage:
#   ./sync-database.sh [OPTIONS]
#
# Options:
#   --source-url          Source database URL (direct, overrides dget)
#   --target-url          Target database URL (direct, overrides dget)
#   -p, --project         Project name for dget (default: mtndev)
#   -s, --source          Source environment (e.g., prd, stg) - required if not using --source-url
#   --target              Target environment (e.g., stg, prd) - required if not using --target-url
#   -k, --key             Database URL key in dotenv (default: N8N_DATABASE_URL)
#   -d, --database        Database name to drop/recreate (extracted from URL if not provided)
#   -o, --output-dir      Directory for dump files (default: .data)
#   --source-pg-version   PostgreSQL version for source (default: 18)
#   --target-pg-version   PostgreSQL version for target (default: 18)
#   -t, --table           Dump only matching table(s) - can be repeated (passed to pg_dump -t)
#   -T, --exclude-table   Do NOT dump matching table(s) - can be repeated (passed to pg_dump -T)
#   -n, --schema          Dump only matching schema(s) - can be repeated (passed to pg_dump -n)
#   -N, --exclude-schema  Do NOT dump matching schema(s) - can be repeated (passed to pg_dump -N)
#   --exclude-table-data  Do NOT dump data for matching table(s) - can be repeated
#   --clean               Clean the dump file (remove ownership/role commands) before restoring
#   -y, --yes             Skip confirmation prompt
#   -h, --help            Show this help message
#
# Examples:
#   # Sync production to staging (using dget)
#   ./sync-database.sh -s prd --target stg
#
#   # Sync using direct URLs with cleaning
#   ./sync-database.sh --source-url "postgres://..." --target-url "postgres://..." --clean
#
#   # Exclude specific tables
#   ./sync-database.sh -s prd --target stg -T logs -T sessions
#
#   # Use different project and key
#   ./sync-database.sh -p myproject -s prd --target stg -k DATABASE_URL

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
PROJECT="mtndev"
SOURCE_ENV=""
TARGET_ENV=""
SOURCE_URL_DIRECT=""
TARGET_URL_DIRECT=""
DB_KEY="N8N_DATABASE_URL"
OUTPUT_DIR=".data"
SKIP_CONFIRM=false
DATABASE_NAME=""
CLEAN_DUMP=false
SOURCE_PG_VERSION="17"
TARGET_PG_VERSION="17"

# Arrays for table/schema filters (can be specified multiple times)
INCLUDE_TABLES=()
EXCLUDE_TABLES=()
INCLUDE_SCHEMAS=()
EXCLUDE_SCHEMAS=()
EXCLUDE_TABLE_DATA=()

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --source-url)
            SOURCE_URL_DIRECT="$2"
            shift 2
            ;;
        --target-url)
            TARGET_URL_DIRECT="$2"
            shift 2
            ;;
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        -s|--source)
            SOURCE_ENV="$2"
            shift 2
            ;;
        --target)
            TARGET_ENV="$2"
            shift 2
            ;;
        -k|--key)
            DB_KEY="$2"
            shift 2
            ;;
        -d|--database)
            DATABASE_NAME="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --source-pg-version)
            SOURCE_PG_VERSION="$2"
            shift 2
            ;;
        --target-pg-version)
            TARGET_PG_VERSION="$2"
            shift 2
            ;;
        -t|--table)
            INCLUDE_TABLES+=("$2")
            shift 2
            ;;
        -T|--exclude-table)
            EXCLUDE_TABLES+=("$2")
            shift 2
            ;;
        -n|--schema)
            INCLUDE_SCHEMAS+=("$2")
            shift 2
            ;;
        -N|--exclude-schema)
            EXCLUDE_SCHEMAS+=("$2")
            shift 2
            ;;
        --exclude-table-data)
            EXCLUDE_TABLE_DATA+=("$2")
            shift 2
            ;;
        --clean)
            CLEAN_DUMP=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            head -40 "$0" | tail -37
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Determine how to get database URLs
if [[ -n "$SOURCE_URL_DIRECT" ]] && [[ -n "$TARGET_URL_DIRECT" ]]; then
    # Use direct URLs
    SOURCE_URL="$SOURCE_URL_DIRECT"
    TARGET_URL="$TARGET_URL_DIRECT"
    echo -e "${BLUE}Using direct database URLs...${NC}"
elif [[ -z "$SOURCE_URL_DIRECT" ]] && [[ -z "$TARGET_URL_DIRECT" ]]; then
    # Use dget - validate environments are provided
    if [[ -z "$SOURCE_ENV" ]] || [[ -z "$TARGET_ENV" ]]; then
        echo -e "${RED}Error: Either provide --source-url/--target-url OR --source/--target environments${NC}"
        echo "Usage: $0 --source-url <url> --target-url <url>"
        echo "   OR: $0 -s <source_env> -t <target_env>"
        echo "Run '$0 --help' for more information"
        exit 1
    fi
    
    if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
        echo -e "${RED}Error: Source and target environments cannot be the same${NC}"
        exit 1
    fi
    
    # Get database URLs using dget
    echo -e "${BLUE}Fetching database URLs using dget...${NC}"
    SOURCE_URL=$(dget -p "$PROJECT" "$SOURCE_ENV" "$DB_KEY")
    TARGET_URL=$(dget -p "$PROJECT" "$TARGET_ENV" "$DB_KEY")
    
    if [[ -z "$SOURCE_URL" ]]; then
        echo -e "${RED}Error: Could not get source database URL${NC}"
        exit 1
    fi
    
    if [[ -z "$TARGET_URL" ]]; then
        echo -e "${RED}Error: Could not get target database URL${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: Both --source-url and --target-url must be provided together, or use --source/--target with dget${NC}"
    exit 1
fi

# Validate URLs are set
if [[ -z "$SOURCE_URL" ]] || [[ -z "$TARGET_URL" ]]; then
    echo -e "${RED}Error: Source and target database URLs are required${NC}"
    exit 1
fi

# Set PostgreSQL binary paths based on versions
SOURCE_PG_DUMP="/opt/homebrew/opt/postgresql@${SOURCE_PG_VERSION}/bin/pg_dump"
TARGET_PSQL="/opt/homebrew/opt/postgresql@${TARGET_PG_VERSION}/bin/psql"

# Validate source PostgreSQL binaries exist
if [[ ! -f "$SOURCE_PG_DUMP" ]]; then
    echo -e "${RED}Error: pg_dump not found at $SOURCE_PG_DUMP${NC}"
    echo -e "${YELLOW}Make sure PostgreSQL ${SOURCE_PG_VERSION} is installed via Homebrew${NC}"
    exit 1
fi

# Validate target PostgreSQL binaries exist
if [[ ! -f "$TARGET_PSQL" ]]; then
    echo -e "${RED}Error: psql not found at $TARGET_PSQL${NC}"
    echo -e "${YELLOW}Make sure PostgreSQL ${TARGET_PG_VERSION} is installed via Homebrew${NC}"
    exit 1
fi

# Parse database name from connection URL (path segment before ?query)
extract_database_name_from_url() {
    echo "$1" | sed -E 's|.*\/([^?]+).*|\1|'
}

# Extract database name from target URL if not provided
if [[ -z "$DATABASE_NAME" ]]; then
    DATABASE_NAME=$(extract_database_name_from_url "$TARGET_URL")
fi

SOURCE_DATABASE_NAME=$(extract_database_name_from_url "$SOURCE_URL")

# Extract connection info for admin operations (without database name)
# We need to connect to 'postgres' database to drop/create the target database
# Replace the database name with 'postgres', preserving any query parameters
if [[ "$TARGET_URL" == *"?"* ]]; then
    # URL has query parameters - split on ? and replace the dbname part
    QUERY_PART="${TARGET_URL#*\?}"
    BASE_PART="${TARGET_URL%\?*}"
    ADMIN_URL="${BASE_PART%/*}/postgres?${QUERY_PART}"
else
    # URL has no query parameters - just replace the last /dbname with /postgres
    ADMIN_URL="${TARGET_URL%/*}/postgres"
fi

# Allow only simple SQL identifiers for safe interpolation (injection guard)
is_safe_identifier() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# After restoring DB A into DB B, Drizzle's migrations table may still be named
# __drizzle_migrations_<source_db>. Rename it to __drizzle_migrations_<target_db>.
repair_drizzle_migration_table() {
    local source_db="$1"
    local target_db="$2"
    local src_table
    local tgt_table

    if [[ "$source_db" == "$target_db" ]]; then
        return 0
    fi

    if ! is_safe_identifier "$source_db" || ! is_safe_identifier "$target_db"; then
        echo -e "${YELLOW}      ⚠ Skipping Drizzle migration table repair: database name from URL is not a safe identifier.${NC}"
        return 0
    fi

    src_table="__drizzle_migrations_${source_db}"
    tgt_table="__drizzle_migrations_${target_db}"

    if ! is_safe_identifier "$src_table" || ! is_safe_identifier "$tgt_table"; then
        echo -e "${YELLOW}      ⚠ Skipping Drizzle migration table repair: derived migration table name is not a safe identifier.${NC}"
        return 0
    fi

    local src_exists
    local tgt_exists
    src_exists=$("$TARGET_PSQL" "$TARGET_URL" -t -A -c \
        "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'drizzle' AND tablename = '${src_table}');")
    tgt_exists=$("$TARGET_PSQL" "$TARGET_URL" -t -A -c \
        "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'drizzle' AND tablename = '${tgt_table}');")

    if [[ "$src_exists" == "t" ]] && [[ "$tgt_exists" == "t" ]]; then
        echo -e "${YELLOW}      ⚠ Drizzle migration tables ${src_table} and ${tgt_table} both exist; manual cleanup may be needed.${NC}"
        return 0
    fi

    if [[ "$src_exists" != "t" ]]; then
        echo -e "${BLUE}      Drizzle migration table repair: ${src_table} not found (nothing to rename).${NC}"
        return 0
    fi

    if [[ "$tgt_exists" == "t" ]]; then
        echo -e "${YELLOW}      ⚠ Drizzle migration table ${tgt_table} already exists; skipping rename.${NC}"
        return 0
    fi

    echo -e "${BLUE}      Renaming Drizzle migration table ${src_table} → ${tgt_table}...${NC}"
    "$TARGET_PSQL" "$TARGET_URL" -c \
        "ALTER TABLE drizzle.\"${src_table}\" RENAME TO \"${tgt_table}\";"
    echo -e "${GREEN}      ✓ Drizzle migration table aligned with target database name${NC}"
}

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Generate dump filename
if [[ -n "$SOURCE_ENV" ]]; then
    DUMP_FILE="$OUTPUT_DIR/${DATABASE_NAME}_${SOURCE_ENV}_$(date '+%Y-%m-%d_%H%M%S').sql"
else
    DUMP_FILE="$OUTPUT_DIR/${DATABASE_NAME}_$(date '+%Y-%m-%d_%H%M%S').sql"
fi

# Show summary
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                    DATABASE SYNC SUMMARY${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
if [[ -n "$SOURCE_ENV" ]] && [[ -n "$TARGET_ENV" ]]; then
    echo -e "Project:         ${GREEN}$PROJECT${NC}"
    echo -e "Source:          ${GREEN}$SOURCE_ENV${NC}"
    echo -e "Target:          ${RED}$TARGET_ENV${NC}"
else
    # Show full URLs (end is most important - database name)
    echo -e "Source URL:      ${GREEN}$SOURCE_URL${NC}"
    echo -e "Target URL:      ${RED}$TARGET_URL${NC}"
fi
echo -e "Database:        ${GREEN}$DATABASE_NAME${NC}"
echo -e "Dump file:       ${GREEN}$DUMP_FILE${NC}"
echo -e "Source PG:       ${GREEN}$SOURCE_PG_VERSION${NC}"
echo -e "Target PG:       ${GREEN}$TARGET_PG_VERSION${NC}"

# Show table/schema filters if any
if [[ ${#INCLUDE_TABLES[@]} -gt 0 ]]; then
    echo -e "Include tables:  ${GREEN}${INCLUDE_TABLES[*]}${NC}"
fi
if [[ ${#EXCLUDE_TABLES[@]} -gt 0 ]]; then
    echo -e "Exclude tables:  ${YELLOW}${EXCLUDE_TABLES[*]}${NC}"
fi
if [[ ${#INCLUDE_SCHEMAS[@]} -gt 0 ]]; then
    echo -e "Include schemas: ${GREEN}${INCLUDE_SCHEMAS[*]}${NC}"
fi
if [[ ${#EXCLUDE_SCHEMAS[@]} -gt 0 ]]; then
    echo -e "Exclude schemas: ${YELLOW}${EXCLUDE_SCHEMAS[*]}${NC}"
fi
if [[ ${#EXCLUDE_TABLE_DATA[@]} -gt 0 ]]; then
    echo -e "Exclude data:    ${YELLOW}${EXCLUDE_TABLE_DATA[*]}${NC}"
fi

echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo ""
if [[ -n "$TARGET_ENV" ]]; then
    echo -e "${RED}⚠️  WARNING: This will DROP and recreate the ${TARGET_ENV} database!${NC}"
else
    echo -e "${RED}⚠️  WARNING: This will DROP and recreate the target database!${NC}"
fi
echo ""

# Confirm unless --yes flag is set
if [[ "$SKIP_CONFIRM" != true ]]; then
    read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
fi

echo ""

# Function to clean PostgreSQL dump file
clean_dump_file() {
    local input_file="$1"
    local output_file="$2"
    
    echo -e "${BLUE}      Cleaning dump file...${NC}"
    
    sed -E \
      -e '/^\\restrict/d' \
      -e '/^SET ROLE/d' \
      -e '/^ALTER SCHEMA.*OWNER TO/d' \
      -e '/^ALTER TYPE.*OWNER TO/d' \
      -e '/^ALTER FUNCTION.*OWNER TO/d' \
      -e '/^ALTER SEQUENCE.*OWNER TO/d' \
      -e '/^ALTER TABLE.*OWNER TO/d' \
      -e '/^ALTER MATERIALIZED VIEW.*OWNER TO/d' \
      -e '/OWNER TO f3slackbot/d' \
      -e '/OWNER TO app_codex/d' \
      -e '/^\\[a-zA-Z]/d' \
      "$input_file" > "$output_file"
    
    local input_size=$(wc -c < "$input_file" | tr -d ' ')
    local output_size=$(wc -c < "$output_file" | tr -d ' ')
    local removed=$((input_size - output_size))
    
    echo -e "${GREEN}      ✓ Cleaned: removed ~$removed bytes${NC}"
}

# Step 1: Dump source database
if [[ -n "$SOURCE_ENV" ]]; then
    echo -e "${BLUE}[1/3] Dumping ${SOURCE_ENV} database (PostgreSQL ${SOURCE_PG_VERSION})...${NC}"
else
    echo -e "${BLUE}[1/3] Dumping source database (PostgreSQL ${SOURCE_PG_VERSION})...${NC}"
fi

# Build pg_dump command with filters
PG_DUMP_CMD=("$SOURCE_PG_DUMP")

# Add table includes
for table in "${INCLUDE_TABLES[@]}"; do
    PG_DUMP_CMD+=("-t" "$table")
done

# Add table excludes
for table in "${EXCLUDE_TABLES[@]}"; do
    PG_DUMP_CMD+=("-T" "$table")
done

# Add schema includes
for schema in "${INCLUDE_SCHEMAS[@]}"; do
    PG_DUMP_CMD+=("-n" "$schema")
done

# Add schema excludes
for schema in "${EXCLUDE_SCHEMAS[@]}"; do
    PG_DUMP_CMD+=("-N" "$schema")
done

# Add exclude table data
for table in "${EXCLUDE_TABLE_DATA[@]}"; do
    PG_DUMP_CMD+=("--exclude-table-data=$table")
done

# Add the database URL
PG_DUMP_CMD+=("$SOURCE_URL")

# Execute the dump
"${PG_DUMP_CMD[@]}" > "$DUMP_FILE"

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo -e "${GREEN}      ✓ Dump complete: $DUMP_FILE ($DUMP_SIZE)${NC}"

# Clean dump file if requested
RESTORE_FILE="$DUMP_FILE"
if [[ "$CLEAN_DUMP" == true ]]; then
    CLEANED_DUMP_FILE="${DUMP_FILE%.sql}_cleaned.sql"
    clean_dump_file "$DUMP_FILE" "$CLEANED_DUMP_FILE"
    RESTORE_FILE="$CLEANED_DUMP_FILE"
fi

# Step 2: Drop and recreate target database
if [[ -n "$TARGET_ENV" ]]; then
    echo -e "${BLUE}[2/3] Dropping and recreating ${TARGET_ENV} database (PostgreSQL ${TARGET_PG_VERSION})...${NC}"
else
    echo -e "${BLUE}[2/3] Dropping and recreating target database (PostgreSQL ${TARGET_PG_VERSION})...${NC}"
fi

# Terminate existing connections
"$TARGET_PSQL" "$ADMIN_URL" -c "
SELECT pg_terminate_backend(pg_stat_activity.pid)
FROM pg_stat_activity
WHERE pg_stat_activity.datname = '$DATABASE_NAME'
  AND pid <> pg_backend_pid();
" 2>/dev/null || true

# Drop and create database
"$TARGET_PSQL" "$ADMIN_URL" -c "DROP DATABASE IF EXISTS \"$DATABASE_NAME\";"
"$TARGET_PSQL" "$ADMIN_URL" -c "CREATE DATABASE \"$DATABASE_NAME\";"
echo -e "${GREEN}      ✓ Database recreated${NC}"

# Install common extensions
echo -e "${BLUE}      Installing common extensions...${NC}"
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS citext;" 2>/dev/null || true
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";" 2>/dev/null || true
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS hstore;" 2>/dev/null || true
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" 2>/dev/null || true
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS btree_gin;" 2>/dev/null || true
"$TARGET_PSQL" "$TARGET_URL" -c "CREATE EXTENSION IF NOT EXISTS btree_gist;" 2>/dev/null || true
echo -e "${GREEN}      ✓ Extensions installed${NC}"

# Step 3: Restore to target database
if [[ -n "$TARGET_ENV" ]]; then
    echo -e "${BLUE}[3/3] Restoring to ${TARGET_ENV} database (PostgreSQL ${TARGET_PG_VERSION})...${NC}"
else
    echo -e "${BLUE}[3/3] Restoring to target database (PostgreSQL ${TARGET_PG_VERSION})...${NC}"
fi
"$TARGET_PSQL" "$TARGET_URL" < "$RESTORE_FILE"
echo -e "${GREEN}      ✓ Restore complete${NC}"

repair_drizzle_migration_table "$SOURCE_DATABASE_NAME" "$DATABASE_NAME"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           DATABASE SYNC COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
if [[ -n "$SOURCE_ENV" ]] && [[ -n "$TARGET_ENV" ]]; then
    echo -e "Source:  ${SOURCE_ENV} → Target: ${TARGET_ENV}"
else
    echo -e "Database sync completed"
fi
echo -e "Dump file saved: $DUMP_FILE"
if [[ "$CLEAN_DUMP" == true ]]; then
    echo -e "Cleaned dump file: $CLEANED_DUMP_FILE"
fi
echo ""



