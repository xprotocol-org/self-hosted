#!/bin/bash
set -e

# Docker Volume Restore Script
# Restores a compressed backup to a specified Docker volume

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/volume_backups"

# Function to show usage
show_usage() {
    echo "Usage: $0 <volume_name> <backup_file.tar.zst>"
    echo ""
    echo "Parameters:"
    echo "  volume_name     Docker volume name to restore to (required)"
    echo "  backup_file     Backup file to restore from (required)"
    echo ""
    echo "Examples:"
    echo "  $0 sentry-postgres sentry-postgres_volume_20241227_143022.tar.zst"
    echo "  $0 my-volume my-volume_volume_20241227_143022.tar.zst"
    echo ""
}

echo "🔄 Starting Docker volume restore..."

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    exit 1
fi

# Function to list available backups
list_backups() {
    echo "📋 Available backups in ${BACKUP_DIR}:"
    if [ -d "${BACKUP_DIR}" ] && [ "$(ls -A "${BACKUP_DIR}"/*.tar.zst 2>/dev/null)" ]; then
        ls -la "${BACKUP_DIR}"/*.tar.zst | while read -r line; do
            file=$(echo "$line" | awk '{print $NF}')
            filename=$(basename "$file")
            size=$(echo "$line" | awk '{print $5}')
            date=$(echo "$line" | awk '{print $6, $7, $8}')
            echo "   📄 ${filename} (${size} bytes, ${date})"
            
            # Show metadata if available
            metadata_file="${file%.tar.zst}_metadata.txt"
            if [ -f "$metadata_file" ]; then
                echo "      📋 Metadata: $(basename "$metadata_file")"
            fi
        done
    else
        echo "   ❌ No backup files found"
        echo "   Run backup_sentry_volume.sh first to create a backup"
        exit 1
    fi
}

# Check arguments
if [ $# -lt 2 ]; then
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 1
    fi
    
    # If only one argument provided, show available backups and usage
    echo "❌ Error: Both volume name and backup file are required"
    echo ""
    list_backups
    echo ""
    show_usage
    exit 1
fi

VOLUME_NAME="$1"
BACKUP_FILE="$2"

echo "🔧 Volume to restore: ${VOLUME_NAME}"

# Check if backup file exists (handle both absolute and relative paths)
if [ ! -f "$BACKUP_FILE" ]; then
    # Try in backup directory
    if [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
        BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
    else
        echo "❌ Error: Backup file not found: $2"
        echo ""
        list_backups
        exit 1
    fi
fi

BACKUP_FILE=$(realpath "$BACKUP_FILE")
BACKUP_FILENAME=$(basename "$BACKUP_FILE")
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

echo "📄 Backup file: ${BACKUP_FILE}"
echo "📊 Backup size: ${BACKUP_SIZE}"

# Show metadata if available
METADATA_FILE="${BACKUP_FILE%.tar.zst}_metadata.txt"
if [ -f "$METADATA_FILE" ]; then
    echo "📋 Backup metadata:"
    cat "$METADATA_FILE" | sed 's/^/   /'
    echo ""
fi

# Check for containers using this volume
CONTAINER_NAMES=$(docker ps --filter volume="${VOLUME_NAME}" --format "{{.Names}}" 2>/dev/null || echo "")
if [ -n "$CONTAINER_NAMES" ]; then
    echo "⚠️  Warning: The following containers are currently using this volume:"
    echo "$CONTAINER_NAMES" | while read -r container; do
        if [ -n "$container" ]; then
            CONTAINER_STATUS=$(docker ps --filter name="^${container}$" --format "{{.Status}}" 2>/dev/null || echo "Unknown")
            echo "   📦 ${container} (${CONTAINER_STATUS})"
        fi
    done
    echo ""
    echo "   These containers must be stopped before restoring the volume"
    echo ""
    read -p "Stop these containers now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🛑 Stopping containers using volume ${VOLUME_NAME}..."
        # Stop the containers
        if [ -n "$CONTAINER_NAMES" ]; then
            echo "$CONTAINER_NAMES" | xargs docker stop
            echo "✅ Containers stopped"
        fi
    else
        echo "❌ Cannot restore while containers are using the volume"
        exit 1
    fi
fi

# Final confirmation
echo ""
echo "⚠️  WARNING: This will completely replace the current volume data!"
echo "   Volume: ${VOLUME_NAME}"
echo "   Backup: ${BACKUP_FILENAME}"
echo ""
read -p "Are you sure you want to proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Restore cancelled by user"
    exit 1
fi

# Check if volume exists and remove it
if docker volume inspect "${VOLUME_NAME}" > /dev/null 2>&1; then
    echo "🗑️  Removing existing volume: ${VOLUME_NAME}"
    docker volume rm "${VOLUME_NAME}"
fi

# Create new volume
echo "📦 Creating new volume: ${VOLUME_NAME}"
docker volume create "${VOLUME_NAME}"

# Restore backup to volume
echo "🚀 Restoring backup to volume (this may take a while)..."
BACKUP_DIR_CONTAINER=$(dirname "$BACKUP_FILE")
BACKUP_FILENAME=$(basename "$BACKUP_FILE")

# Set up zstd decompression
DOCKER_IMAGE="alpine:latest"
INSTALL_CMD="apk add --no-cache zstd && "

# Check if this is a zstd backup file
if [[ "$BACKUP_FILENAME" == *.tar.zst ]]; then
    echo "🗜️  Detected zstd compression"
    RESTORE_CMD="cd /target && ${INSTALL_CMD}zstd -d -c /backup/$BACKUP_FILENAME | tar xf -"
else
    echo "❌ Error: This script only supports zstd compressed backups (.tar.zst files)"
    echo "   Found: $BACKUP_FILENAME"
    echo "   Expected: *.tar.zst"
    exit 1
fi

docker run --rm \
    -v "${VOLUME_NAME}:/target" \
    -v "${BACKUP_DIR_CONTAINER}:/backup:ro" \
    --name "sentry-volume-restore-$(date +%s)" \
    "${DOCKER_IMAGE}" \
    sh -c "${RESTORE_CMD}"

if [ $? -eq 0 ]; then
    echo "✅ Volume restore completed successfully!"
    echo "📦 Volume: ${VOLUME_NAME}"
    echo "📄 Restored from: ${BACKUP_FILENAME}"
    
    # Verify volume contents
    RESTORED_FILES=$(docker run --rm -v "${VOLUME_NAME}:/check:ro" alpine:latest sh -c "find /check -type f | wc -l")
    echo "📊 Restored files count: ${RESTORED_FILES}"
    
    echo ""
    echo "🎉 Restore process completed!"
    echo ""
    echo "📝 Next steps:"
    echo "   1. Start containers that use this volume: docker start <container_names>"
    echo "   2. Verify volume contents and functionality"
    echo "   3. Check application functionality as needed"
else
    echo "❌ Error: Volume restore failed"
    exit 1
fi
