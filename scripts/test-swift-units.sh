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

swiftc -parse-as-library \
  "$ROOT/srota/srota/AgentRegionLogic.swift" \
  "$ROOT/scripts/test-agent-region-logic.swift" \
  -o /tmp/srota-region-test
/tmp/srota-region-test

swiftc -parse-as-library \
  "$ROOT/srota/srota/GitHubHelpers.swift" \
  "$ROOT/srota/srota/IssuePopoverLogic.swift" \
  "$ROOT/scripts/test-issue-popover-logic.swift" \
  -o /tmp/srota-issue-popover-logic-test
/tmp/srota-issue-popover-logic-test

swiftc -parse-as-library \
  "$ROOT/srota/srota/RepositoryFilterState.swift" \
  "$ROOT/scripts/test-repository-filter-state.swift" \
  -o /tmp/srota-repository-filter-test
/tmp/srota-repository-filter-test

swiftc -parse-as-library \
  "$ROOT/srota/srota/FlowRefetchLogic.swift" \
  "$ROOT/scripts/test-flow-refetch-logic.swift" \
  -o /tmp/srota-flow-refetch-test
/tmp/srota-flow-refetch-test

swiftc -parse-as-library \
  "$ROOT/srota/srota-daemon/RingBuffer.swift" \
  "$ROOT/srota/srota-daemon/DaemonProtocol.swift" \
  "$ROOT/srota/srota-daemon/PTYRegistry.swift" \
  "$ROOT/srota/srota-daemon/ClientSession.swift" \
  "$ROOT/srota/srota-daemon/PTYProcess.swift" \
  "$ROOT/scripts/test-daemon-concurrency.swift" \
  -o /tmp/srota-daemon-concurrency-test
/tmp/srota-daemon-concurrency-test
