#!/bin/bash
set -e

# Sentry PostgreSQL Database Export Script
# Exports the current Sentry database to the host directory for version upgrades

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/db_backup"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

EXPORT_FILE="sentry_db_export_${TIMESTAMP}.dump"

# Function to show usage
show_usage() {
    echo "Usage: $0 <service_name>"
    echo ""
    echo "Parameters:"
    echo "  service_name    PostgreSQL service name (required)"
    echo ""
    echo "Examples:"
    echo "  $0 postgres-real      # Use postgres-real service"
    echo "  $0 my-postgres        # Use custom service name"
    echo ""
}

# Check arguments
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 1
fi

SERVICE_NAME="$1"

echo "🔄 Starting Sentry PostgreSQL database export..."
echo "🔧 Using PostgreSQL service: ${SERVICE_NAME}"

# Check if docker compose is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    exit 1
fi

# Validate service name exists in docker-compose
if ! docker compose config --services | grep -q "^${SERVICE_NAME}$"; then
    echo "❌ Error: Service '${SERVICE_NAME}' not found in docker-compose configuration"
    echo "   Available services:"
    docker compose config --services | sed 's/^/     /'
    exit 1
fi

# Check if containers are running
if ! docker compose ps "${SERVICE_NAME}" | grep -q "Up"; then
    echo "❌ Error: PostgreSQL container (${SERVICE_NAME}) is not running"
    echo "   Please start the containers with: docker compose up -d"
    exit 1
fi

# Create export directory
mkdir -p "${EXPORT_DIR}"

echo "📁 Export directory: ${EXPORT_DIR}"
echo "📄 Export file: ${EXPORT_FILE}"

# Get database connection info
DB_NAME="postgres"
DB_USER="postgres"

echo "🔍 Checking database connection..."
if ! docker compose exec "${SERVICE_NAME}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" > /dev/null 2>&1; then
    echo "❌ Error: Cannot connect to PostgreSQL database"
    exit 1
fi

echo "✅ Database connection verified"

# Get database size for reference
DB_SIZE=$(docker compose exec "${SERVICE_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'));" | xargs)
echo "📊 Database size: ${DB_SIZE}"

# Get more detailed size information
echo "🔍 Analyzing database content..."
TABLE_COUNT=$(docker compose exec "${SERVICE_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | xargs)
echo "📋 Number of tables: ${TABLE_COUNT}"

# Check for large tables
echo "📊 Top 5 largest tables:"
docker compose exec "${SERVICE_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    pg_total_relation_size(schemaname||'.'||tablename) as size_bytes
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY size_bytes DESC 
LIMIT 5;" | sed 's/^/   /'

# Export database schema and data using custom format with compression
echo "🚀 Exporting database (this may take a while for large databases)..."
docker compose exec "${SERVICE_NAME}" pg_dump \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --verbose \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --create \
    --format=custom \
    --compress=9 \
    --blobs \
    --file=/tmp/export.dump

# Copy the compressed dump file from container to host
docker compose cp "${SERVICE_NAME}":/tmp/export.dump "${EXPORT_DIR}/${EXPORT_FILE}"

# Clean up temporary file in container
docker compose exec "${SERVICE_NAME}" rm -f /tmp/export.dump

if [ $? -eq 0 ]; then
    EXPORT_SIZE=$(du -h "${EXPORT_DIR}/${EXPORT_FILE}" | cut -f1)
    echo "✅ Database export completed successfully!"
    echo "📄 Export file: ${EXPORT_DIR}/${EXPORT_FILE}"
    echo "📊 Export size: ${EXPORT_SIZE}"
    
    # Verify the export file integrity
    echo "🔍 Verifying export file integrity..."
    docker compose exec "${SERVICE_NAME}" pg_restore --list "${EXPORT_DIR}/${EXPORT_FILE}" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Export file integrity verified"
        # Get export statistics
        EXPORT_OBJECTS=$(docker compose exec "${SERVICE_NAME}" pg_restore --list "${EXPORT_DIR}/${EXPORT_FILE}" 2>/dev/null | wc -l | xargs)
        echo "📋 Export contains ${EXPORT_OBJECTS} database objects"
    else
        echo "⚠️  Warning: Could not verify export file integrity"
    fi
    
    # Create a metadata file
    cat > "${EXPORT_DIR}/${EXPORT_FILE%.dump}_metadata.txt" << EOF
Export Timestamp: ${TIMESTAMP}
Database Name: ${DB_NAME}
Database User: ${DB_USER}
Original Database Size: ${DB_SIZE}
Export File Size: ${EXPORT_SIZE}
PostgreSQL Version: $(docker compose exec "${SERVICE_NAME}" psql -U "${DB_USER}" -t -c "SELECT version();" | xargs)
Sentry Version: $(docker compose exec web sentry --version 2>/dev/null || echo "Unable to determine")
Export Command: pg_dump -U ${DB_USER} -d ${DB_NAME} --verbose --no-owner --no-privileges --clean --if-exists --create --format=custom --compress=9 --blobs
EOF
    
    echo "📋 Metadata saved to: ${EXPORT_DIR}/${EXPORT_FILE%.dump}_metadata.txt"
    echo ""
    echo "🎉 Export process completed!"
    echo "   You can now upgrade PostgreSQL and use import_sentry_db.sh to import this data"
else
    echo "❌ Error: Database export failed"
    exit 1
fi
