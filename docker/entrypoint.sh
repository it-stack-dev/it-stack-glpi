#!/bin/bash
# entrypoint.sh — IT-Stack glpi container entrypoint
set -euo pipefail

echo "Starting IT-Stack GLPI (Module 17)..."

# Source any environment overrides
if [ -f /opt/it-stack/glpi/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/glpi/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
