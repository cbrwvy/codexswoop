#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No Codex/application launches, process signals, network, auth or Keychain operations.
python3 -B -m unittest discover -s Tests/IsolationLab -p 'test_*.py' -v
