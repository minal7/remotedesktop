#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec /usr/bin/python3 "$ROOT/host-mac/scripts/acceptance/run_job.py" "$@"
