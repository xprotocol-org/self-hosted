#!/bin/bash
set -e

# Sentry Volume Backup Script with Parallel Compression Support
# Creates a compressed backup of a specified Docker volume using the best available compression tool

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/volume_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Default settings for zstd compression
COMPRESSION_LEVEL="3"
THREADS=$(nproc 2>/dev/null || echo "4")

# Function to show usage
show_usage() {
    echo "Usage: $0 <volume_name> [options]"
    echo ""
    echo "Parameters:"
    echo "  volume_name    Docker volume name to backup (required)"
    echo ""
    echo "Options:"
    echo "  -l, --level LEVEL         Compression level 1-9 (default: 3)"
    echo "  -t, --threads THREADS     Number of threads (default: auto-detect)"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Compression: Uses zstd (Zstandard) for fast, modern compression"
    echo ""
    echo "Examples:"
    echo "  $0 sentry-postgres                    # Standard zstd compression"
    echo "  $0 sentry-postgres -l 1 -t 8        # Ultra-fast compression"
    echo "  $0 sentry-postgres -l 9             # Maximum compression"
    echo ""
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Parse arguments
VOLUME_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--level)
            COMPRESSION_LEVEL="$2"
            shift 2
            ;;
        -t|--threads)
            THREADS="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$VOLUME_NAME" ]; then
                VOLUME_NAME="$1"
            else
                echo "❌ Multiple volume names provided"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$VOLUME_NAME" ]; then
    echo "❌ Volume name is required"
    show_usage
    exit 1
fi

# Set zstd compression settings
DOCKER_IMAGE="alpine:latest"
INSTALL_CMD="apk add --no-cache zstd"
COMPRESS_CMD="zstd -$COMPRESSION_LEVEL -T$THREADS"
FILE_EXT="tar.zst"

BACKUP_FILE="${VOLUME_NAME}_volume_${TIMESTAMP}.${FILE_EXT}"

echo "🔄 Starting Docker volume backup..."
echo "🔧 Volume to backup: ${VOLUME_NAME}"
echo "🗜️  Compression: zstd (level ${COMPRESSION_LEVEL})"
echo "🧵 Threads: ${THREADS}"

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    exit 1
fi

# Check if the volume exists
if ! docker volume inspect "${VOLUME_NAME}" > /dev/null 2>&1; then
    echo "❌ Error: Volume '${VOLUME_NAME}' does not exist"
    echo "   Available volumes:"
    docker volume ls
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

echo "📁 Backup directory: ${BACKUP_DIR}"
echo "📄 Backup file: ${BACKUP_FILE}"

# Get volume information
VOLUME_SIZE=$(docker system df -v | grep "${VOLUME_NAME}" | awk '{print $3}' || echo "Unknown")
VOLUME_MOUNTPOINT=$(docker volume inspect "${VOLUME_NAME}" --format '{{ .Mountpoint }}' 2>/dev/null || echo "Unknown")

echo "📊 Volume size: ${VOLUME_SIZE}"
echo "📍 Volume mountpoint: ${VOLUME_MOUNTPOINT}"

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
    echo "   For consistent backups, consider stopping these containers first"
    echo ""
    read -p "Continue with backup while containers are running? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Backup cancelled by user"
        exit 1
    fi
fi

# Create backup using zstd compression
echo "🚀 Creating volume backup with zstd compression (${THREADS} threads)..."

# Record start time for performance measurement
START_TIME=$(date +%s)

# Build the Docker command
DOCKER_CMD="cd /source && "

# Add installation command if needed
if [ -n "$INSTALL_CMD" ]; then
    DOCKER_CMD="${DOCKER_CMD}${INSTALL_CMD} && "
fi

# Add the backup command with parallel compression
DOCKER_CMD="${DOCKER_CMD}tar -cf - . | ${COMPRESS_CMD} > /backup/${BACKUP_FILE}"

# Run the backup with Alpine Linux
docker run --rm \
    -v "${VOLUME_NAME}:/source:ro" \
    -v "${BACKUP_DIR}:/backup" \
    --name "sentry-volume-backup-${TIMESTAMP}" \
    "${DOCKER_IMAGE}" \
    sh -c "${DOCKER_CMD}"

# Calculate backup time
END_TIME=$(date +%s)
BACKUP_TIME=$((END_TIME - START_TIME))

if [ $? -eq 0 ]; then
    BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
    echo "✅ Volume backup completed successfully!"
    echo "📄 Backup file: ${BACKUP_DIR}/${BACKUP_FILE}"
    echo "📊 Backup size: ${BACKUP_SIZE}"
    echo "⏱️  Backup time: ${BACKUP_TIME} seconds"
    echo "🗜️  Compression: zstd (level ${COMPRESSION_LEVEL}, ${THREADS} threads)"
    
    # Create a metadata file
    cat > "${BACKUP_DIR}/${BACKUP_FILE%.*.*}_metadata.txt" << EOF
Backup Timestamp: ${TIMESTAMP}
Volume Name: ${VOLUME_NAME}
Original Volume Size: ${VOLUME_SIZE}
Volume Mountpoint: ${VOLUME_MOUNTPOINT}
Backup File Size: ${BACKUP_SIZE}
Backup Time: ${BACKUP_TIME} seconds
Compression Method: zstd
Compression Level: ${COMPRESSION_LEVEL}
Threads Used: ${THREADS}
Docker Image: ${DOCKER_IMAGE}
Containers Using Volume: ${CONTAINER_NAMES}
Docker Version: $(docker --version)
Backup Method: Docker volume mount with parallel compression
Backup Command: docker run --rm -v ${VOLUME_NAME}:/source:ro -v ${BACKUP_DIR}:/backup ${DOCKER_IMAGE} sh -c "${DOCKER_CMD}"
EOF
    
    echo "📋 Metadata saved to: ${BACKUP_DIR}/${BACKUP_FILE%.*.*}_metadata.txt"
    echo ""
    echo "🎉 Parallel backup process completed!"
    echo ""
    echo "📝 To restore this backup:"
    echo "   Use the restore script: ./restore_sentry_volume.sh ${VOLUME_NAME} ${BACKUP_FILE}"
    echo ""
    echo "💡 Performance tip: This backup used zstd compression"
    if [ "$COMPRESSION_LEVEL" != "1" ]; then
        echo "   For maximum speed, try: $0 ${VOLUME_NAME} -l 1"
    else
        echo "   For better compression, try: $0 ${VOLUME_NAME} -l 9"
    fi
else
    echo "❌ Error: Volume backup failed"
    # Clean up failed backup file if it exists
    [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ] && rm -f "${BACKUP_DIR}/${BACKUP_FILE}"
    exit 1
fi
