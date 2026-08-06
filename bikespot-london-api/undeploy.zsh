#!/usr/bin/env zsh
set -euo pipefail

# ---- Config ----
HOST="${DEPLOY_HOST:?DEPLOY_HOST is not set}"

# Get the directory name of this script to use as project name
SCRIPT_DIR="${0:a:h}"
PROJECT_NAME="${SCRIPT_DIR:t}"

REMOTE_DIR="${HOME}/dev/${PROJECT_NAME}"

# Generate service label based on project name
SERVICE_LABEL="com.${PROJECT_NAME}.api"

# ----------------

echo "==> Stopping and removing launchd service: ${SERVICE_LABEL}"
ssh "$HOST" "
  set -e
  PLIST=\"\$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist\"
  DOMAIN=\"gui/\$(id -u)\"

  # Check if service is loaded
  if launchctl print \"\$DOMAIN/$SERVICE_LABEL\" >/dev/null 2>&1; then
    echo 'Service is loaded, stopping and unloading...'

    # Disable the service
    launchctl disable \"gui/\$(id -u)/$SERVICE_LABEL\" 2>/dev/null || true

    # Stop the service
    launchctl kill SIGTERM \"gui/\$(id -u)/$SERVICE_LABEL\" 2>/dev/null || true

    # Give it a moment to stop gracefully
    sleep 1

    # Bootout (unload) the service
    launchctl bootout \"gui/\$(id -u)/$SERVICE_LABEL\" 2>/dev/null || true

    echo 'Service stopped and unloaded'
  else
    echo 'Service is not currently loaded'
  fi

  # Remove the plist file
  if [[ -f \"\$PLIST\" ]]; then
    echo 'Removing plist file...'
    rm -f \"\$PLIST\"
    echo 'Plist removed'
  else
    echo 'Plist file does not exist'
  fi

  echo ''
  echo '✅ Service undeployed successfully'
  echo ''
  echo 'Files remain at: ${REMOTE_DIR}'
  echo 'To remove files, run:'
  echo '  ssh ${HOST} \"rm -rf ${REMOTE_DIR}\"'
"

echo ""
echo "✅ Undeploy complete."
echo ""
echo "The service has been removed from launchd."
echo "Files remain at: ${HOST}:${REMOTE_DIR}"
echo ""
echo "To manually remove files, run:"
echo "  ssh ${HOST} \"rm -rf ${REMOTE_DIR}\""
