#!/bin/bash
set -e

# Sentry PostgreSQL Database Import Script
# Imports a previously exported database dump to a new PostgreSQL version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/db_backup"
VOLUME_BACKUP_DIR="${SCRIPT_DIR}/volume_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

echo "🔄 Starting Sentry PostgreSQL database import..."

# Function to show usage
show_usage() {
    echo "Usage: $0 <export_file.sql|export_file.dump> <service_name>"
    echo ""
    echo "Parameters:"
    echo "  export_file     Export file to import (.sql or .dump format) - required"
    echo "  service_name    PostgreSQL service name - required"
    echo ""
    echo "Supports both SQL (.sql) and compressed dump (.dump) formats."
    echo ""
    echo "Examples:"
    echo "  $0 sentry_db_export_20241227_143022.sql postgres-real"
    echo "  $0 sentry_db_export_20241227_143022.dump my-postgres"
    echo ""
    echo "To see available export files, use: ls -la db_backup/"
    echo ""
}

# Function to list available export files
list_export_files() {
    echo "📁 Available export files in ${BACKUP_DIR}:"
    if [ -d "${BACKUP_DIR}" ]; then
        found_files=false
        
        # List SQL files
        if ls "${BACKUP_DIR}"/*.sql >/dev/null 2>&1; then
            ls -la "${BACKUP_DIR}"/*.sql | while read -r line; do
                file=$(echo "$line" | awk '{print $NF}')
                filename=$(basename "$file")
                if [ -f "${BACKUP_DIR}/${filename%.sql}_metadata.txt" ]; then
                    echo "  📄 $filename (SQL format)"
                    echo "     $(grep "Export Timestamp:" "${BACKUP_DIR}/${filename%.sql}_metadata.txt" 2>/dev/null || echo "     No metadata available")"
                    echo "     $(grep "Original Database Size:" "${BACKUP_DIR}/${filename%.sql}_metadata.txt" 2>/dev/null || echo "")"
                    echo ""
                else
                    echo "  📄 $filename (SQL format, no metadata)"
                    echo ""
                fi
            done
            found_files=true
        fi
        
        # List dump files
        if ls "${BACKUP_DIR}"/*.dump >/dev/null 2>&1; then
            ls -la "${BACKUP_DIR}"/*.dump | while read -r line; do
                file=$(echo "$line" | awk '{print $NF}')
                filename=$(basename "$file")
                if [ -f "${BACKUP_DIR}/${filename%.dump}_metadata.txt" ]; then
                    echo "  📦 $filename (Compressed dump format)"
                    echo "     $(grep "Export Timestamp:" "${BACKUP_DIR}/${filename%.dump}_metadata.txt" 2>/dev/null || echo "     No metadata available")"
                    echo "     $(grep "Original Database Size:" "${BACKUP_DIR}/${filename%.dump}_metadata.txt" 2>/dev/null || echo "")"
                    echo ""
                else
                    echo "  📦 $filename (Compressed dump format, no metadata)"
                    echo ""
                fi
            done
            found_files=true
        fi
        
        if [ "$found_files" = false ]; then
            echo "  ❌ No export files found. Please run export_sentry_db.sh first."
        fi
    else
        echo "  ❌ Export directory does not exist. Please run export_sentry_db.sh first."
    fi
}

# Check arguments
if [ $# -lt 2 ]; then
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 1
    fi
    
    # If only one argument provided, show available files and usage
    echo "❌ Error: Both export file and service name are required"
    echo ""
    list_export_files
    echo ""
    show_usage
    exit 1
fi

EXPORT_FILE="$1"
SERVICE_NAME="$2"

echo "🔧 Using PostgreSQL service: ${SERVICE_NAME}"

# Validate service name exists in docker-compose
if ! docker compose config --services | grep -q "^${SERVICE_NAME}$"; then
    echo "❌ Error: Service '${SERVICE_NAME}' not found in docker-compose configuration"
    echo "   Available services:"
    docker compose config --services | sed 's/^/     /'
    exit 1
fi

# Check if export file exists
if [ ! -f "${BACKUP_DIR}/${EXPORT_FILE}" ]; then
    echo "❌ Error: Export file '${BACKUP_DIR}/${EXPORT_FILE}' not found"
    echo ""
    list_export_files
    exit 1
fi

# Check if docker compose is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    exit 1
fi

echo "📄 Using export file: ${BACKUP_DIR}/${EXPORT_FILE}"

# Show metadata if available
if [[ "${EXPORT_FILE}" == *.sql ]]; then
    METADATA_FILE="${BACKUP_DIR}/${EXPORT_FILE%.sql}_metadata.txt"
elif [[ "${EXPORT_FILE}" == *.dump ]]; then
    METADATA_FILE="${BACKUP_DIR}/${EXPORT_FILE%.dump}_metadata.txt"
else
    METADATA_FILE=""
fi

if [ -n "${METADATA_FILE}" ] && [ -f "${METADATA_FILE}" ]; then
    echo "📋 Export metadata:"
    cat "${METADATA_FILE}" | sed 's/^/   /'
    echo ""
fi

# Confirmation prompt
echo "⚠️  WARNING: This will:"
echo "   1. Stop all Sentry containers"
echo "   2. Backup the current PostgreSQL volume"
echo "   3. Remove the current PostgreSQL volume"
echo "   4. Start PostgreSQL with a clean database"
echo "   5. Restore data from the export file"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Operation cancelled"
    exit 1
fi

# Create backup directories
mkdir -p "${BACKUP_DIR}"
mkdir -p "${VOLUME_BACKUP_DIR}"

echo "🛑 Stopping Sentry containers..."
docker compose down

# Backup current PostgreSQL volume
POSTGRES_VOLUME="sentry-postgres"
echo "💾 Backing up current PostgreSQL volume..."

if docker volume inspect "${POSTGRES_VOLUME}" > /dev/null 2>&1; then
    BACKUP_FILE="${VOLUME_BACKUP_DIR}/postgres_volume_backup_${TIMESTAMP}.tar.gz"
    echo "   Creating backup: ${BACKUP_FILE}"
    
    # Create a temporary container to backup the volume
    docker run --rm \
        -v "${POSTGRES_VOLUME}:/source:ro" \
        -v "${VOLUME_BACKUP_DIR}:/backup" \
        alpine:latest \
        tar czf "/backup/postgres_volume_backup_${TIMESTAMP}.tar.gz" -C /source .
    
    if [ $? -eq 0 ]; then
        BACKUP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
        echo "✅ Volume backup completed: ${BACKUP_SIZE}"
    else
        echo "❌ Error: Volume backup failed"
        exit 1
    fi
else
    echo "ℹ️  PostgreSQL volume does not exist, skipping backup"
fi

# Remove the PostgreSQL volume to start fresh
echo "🗑️  Removing current PostgreSQL volume..."
if docker volume inspect "${POSTGRES_VOLUME}" > /dev/null 2>&1; then
    docker volume rm "${POSTGRES_VOLUME}"
    echo "✅ PostgreSQL volume removed"
else
    echo "ℹ️  PostgreSQL volume does not exist"
fi

# Create fresh PostgreSQL volume
echo "📦 Creating fresh PostgreSQL volume..."
docker volume create "${POSTGRES_VOLUME}"
echo "✅ Fresh PostgreSQL volume created"

# Start only PostgreSQL to initialize clean database
echo "🚀 Starting PostgreSQL with clean database..."
docker compose up -d "${SERVICE_NAME}"

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
    if docker compose exec "${SERVICE_NAME}" pg_isready -U postgres > /dev/null 2>&1; then
        echo "✅ PostgreSQL is ready"
        break
    fi
    echo "   Waiting... (${i}/30)"
    sleep 2
done

if [ $i -eq 30 ]; then
    echo "❌ Error: PostgreSQL failed to start within 60 seconds"
    exit 1
fi

# Restore the database
echo "📥 Importing database from export file..."
echo "   This may take a while for large databases..."

# Determine restore method based on file extension
if [[ "${EXPORT_FILE}" == *.sql ]]; then
    echo "   Using psql for SQL format..."
    # Import SQL file
    docker compose exec -T "${SERVICE_NAME}" psql -U postgres < "${BACKUP_DIR}/${EXPORT_FILE}"
elif [[ "${EXPORT_FILE}" == *.dump ]]; then
    echo "   Using pg_restore for compressed dump format..."
    # Copy dump file to container
    docker compose cp "${BACKUP_DIR}/${EXPORT_FILE}" "${SERVICE_NAME}":/tmp/restore.dump
    # Import using pg_restore
    docker compose exec "${SERVICE_NAME}" pg_restore \
        -U postgres \
        -d postgres \
        --verbose \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        /tmp/restore.dump
    # Clean up temporary file
    docker compose exec "${SERVICE_NAME}" rm -f /tmp/restore.dump
else
    echo "❌ Error: Unsupported file format. Use .sql or .dump files."
    exit 1
fi

if [ $? -eq 0 ]; then
echo "✅ Database import completed successfully!"
    
    # Verify the restore
    echo "🔍 Verifying imported database..."
    IMPORTED_SIZE=$(docker compose exec "${SERVICE_NAME}" psql -U postgres -t -c "SELECT pg_size_pretty(pg_database_size('postgres'));" | xargs)
    echo "📊 Imported database size: ${IMPORTED_SIZE}"
    
    # Check some basic tables
    TABLE_COUNT=$(docker compose exec "${SERVICE_NAME}" psql -U postgres -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | xargs)
    echo "📋 Number of tables: ${TABLE_COUNT}"
    
    echo ""
    echo "🎉 Database import process completed!"
    echo "   You can now start all Sentry services with: docker compose up -d"
    
    # Create import log
    cat > "${BACKUP_DIR}/import_log_${TIMESTAMP}.txt" << EOF
Import Timestamp: ${TIMESTAMP}
Export File Used: ${EXPORT_FILE}
Volume Backup: postgres_volume_backup_${TIMESTAMP}.tar.gz
Imported Database Size: ${IMPORTED_SIZE}
Number of Tables: ${TABLE_COUNT}
PostgreSQL Version: $(docker compose exec "${SERVICE_NAME}" psql -U postgres -t -c "SELECT version();" | xargs)
EOF
    
    echo "📋 Import log saved to: ${BACKUP_DIR}/import_log_${TIMESTAMP}.txt"
    
else
    echo "❌ Error: Database import failed"
    echo ""
    echo "🔧 To recover, you can:"
    echo "   1. Stop containers: docker compose down"
    echo "   2. Remove volume: docker volume rm ${POSTGRES_VOLUME}"
    echo "   3. Restore backup: docker run --rm -v ${POSTGRES_VOLUME}:/target -v ${VOLUME_BACKUP_DIR}:/backup alpine:latest tar xzf /backup/postgres_volume_backup_${TIMESTAMP}.tar.gz -C /target"
    echo "   4. Start containers: docker compose up -d"
    exit 1
fi
