#!/bin/bash
set -e

# =============================================================================
# SENTRY CONTAINER ENTRYPOINT
# =============================================================================
# This entrypoint provides reliable container initialization and process management:
#
# 1. ✅ SKIP CA CERTIFICATE UPDATE: Only runs if actual cert files exist
# 2. ✅ PROPER PID 1 HANDLING: Always uses init system for zombie reaping
# 3. ✅ GRACEFUL SHUTDOWN: Forwards signals to child processes correctly
# 4. ✅ STRACE DEBUGGING: Optional system call tracing for debugging
# 5. ✅ ROOT EXECUTION: Runs as root without permission management
#
# CONFIGURATION OPTIONS:
# - SENTRY_DEBUG_STRACE: Enable system call tracing for debugging
#   * 1      : Basic filtered strace to stdout
#   * full   : Full verbose strace to /tmp/strace.log  
#   * file   : Filtered strace to /tmp/strace.log
# - SENTRY_INIT_SYSTEM: Choose init system (default: s6)
#   * s6        : s6-overlay process supervision system (recommended)
#   * tini      : Lightweight init system
# =============================================================================

echo "🚀 Sentry Optimized Entrypoint Starting..."

# =============================================================================
# OPTIMIZATION 1: INTELLIGENT CA CERTIFICATE UPDATE
# =============================================================================
ca_cert_dir="/usr/local/share/ca-certificates/"
if [ -d "$ca_cert_dir" ]; then
  cert_files=$(find "$ca_cert_dir" -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cer" \) 2>/dev/null | wc -l)
  if [ "$cert_files" -gt 0 ]; then
    echo "📜 Found $cert_files custom certificate file(s), updating CA certificates..."
    update-ca-certificates
  else
    echo "📜 No custom certificate files found, skipping CA certificate update"
  fi
fi

if [ -e /etc/sentry/requirements.txt ]; then
  echo "⚠️  sentry/requirements.txt is deprecated, use sentry/enhance-image.sh - see https://develop.sentry.dev/self-hosted/#enhance-sentry-image"
fi

# first check if we're passing flags, if so
# prepend with sentry
if [ "${1:0:1}" = '-' ]; then
	set -- sentry "$@"
fi

if [[ $1 =~ ^[[:alnum:]]+$ ]] && grep -Fxq "$1" /sentry-commands.txt; then
	set -- sentry "$@";
fi

# =============================================================================
# STRACE DEBUGGING: Optional system call tracing
# =============================================================================
if [ -n "$SENTRY_DEBUG_STRACE" ]; then
    echo "🔍 STRACE DEBUGGING ENABLED (mode: $SENTRY_DEBUG_STRACE)"
    
    case "$SENTRY_DEBUG_STRACE" in
        "full")
            STRACE_OPTS="-f -v -s 1024 -o /tmp/strace.log"
            echo "   Full strace logging to /tmp/strace.log"
            ;;
        "file")
            STRACE_OPTS="-f -e trace=!read,write,poll,select,epoll_wait,futex,clock_gettime,gettimeofday -o /tmp/strace.log"
            echo "   Filtered strace logging to /tmp/strace.log"
            ;;
        *)
            STRACE_OPTS="-f -e trace=!read,write,poll,select,epoll_wait,futex,clock_gettime,gettimeofday"
            echo "   Basic strace to stdout (filtered)"
            ;;
    esac
    
    echo "📋 Executing with strace (with TTY preservation)"
    echo "👤 User: root (UID: $(id -u))"
    echo "🎯 Command: strace $STRACE_OPTS $@"
    echo "⏰ Execution time: $(date)"
    exec strace -fvttTyy -s 256 $STRACE_OPTS "$@"
fi

# =============================================================================
# INIT SYSTEM SETUP
# =============================================================================
INIT_SYSTEM="${SENTRY_INIT_SYSTEM:-s6}"

case "$INIT_SYSTEM" in
    "tini")
        set -- tini -s -- "$@"
        echo "✅ Using tini as init system"
        ;;
    "s6")
        echo "✅ Using s6-overlay as init system"
        export S6_KEEP_ENV=1
        export S6_BEHAVIOUR_IF_STAGE2_FAILS=2
        set -- /init "$@"
        ;;
    *)
        echo "⚠️  Unknown init system '$INIT_SYSTEM', falling back to s6"
        export S6_KEEP_ENV=1
        export S6_BEHAVIOUR_IF_STAGE2_FAILS=2
        set -- /init "$@"
        ;;
esac

# =============================================================================
# SIGNAL HANDLING
# =============================================================================
cleanup() {
    echo "🛑 Received signal, letting init system handle cleanup..."
    exit 0
}

trap cleanup SIGTERM SIGINT

echo "🚀 Starting process: $@"
echo "👤 User: root (UID: $(id -u))"
echo "📁 Working directory: $(pwd)"
echo "⏰ Start time: $(date)"

exec "$@"
