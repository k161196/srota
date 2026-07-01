#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

swiftc -parse-as-library \
  "$ROOT/srota/srota/ResizeLogic.swift" \
  "$ROOT/scripts/test-resize-logic.swift" \
  -o /tmp/srota-resize-test
/tmp/srota-resize-test

swiftc -parse-as-library \
  "$ROOT/srota/srota/AgentNotificationRouting.swift" \
  "$ROOT/scripts/test-agent-notification-state.swift" \
  -o /tmp/srota-routing-test
/tmp/srota-routing-test
