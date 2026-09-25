#!/bin/bash
# make-requirements.sh — print SMJobBless signing-requirement strings after you
# have signed BOTH app and helper with the same Team ID.
# Usage: ./scripts/make-requirements.sh /path/to/App.app /path/to/helper
set -euo pipefail
APP="${1:?usage: $0 /path/to/App.app /path/to/helper}"
HELPER="${2:?usage: $0 /path/to/App.app /path/to/helper}"
echo "=== app designation (goes in helper SMAuthorizedClients) ==="
codesign -dr - "$APP" 2>&1 | sed 's/^designated => //'
echo
echo "=== helper designation (goes in app SMPrivilegedExecutables) ==="
codesign -dr - "$HELPER" 2>&1 | sed 's/^designated => //'
