#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"
exec python3 "$repository/scripts/release_artifact.py" package "$@"
