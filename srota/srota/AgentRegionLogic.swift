import SwiftUI

// A "region" is an ordered group of 1+ agents evenly tiled together in one direction. A lone open
// agent is simply a region with a single member — there's no separate "standalone" case, which is
// what lets a freshly-opened agent and a multi-agent split share one attach/render/minimize path
// instead of two parallel mechanisms (that duplication was the root cause of earlier bugs, e.g. a
// blank pane when moving an attachment between the single-view and split-view code paths).
//
// Multiple regions can be open at once (e.g. a lone agent next to a 3-way split); AgentsPanel tiles
// all open regions evenly side by side. Within a region, "Add to split" has no cap — a region can
// grow to any number of members, always evenly divided in whichever direction it was first split.
struct AgentRegion: Identifiable {
    let id: UUID
    var direction: Axis
    var memberIDs: [String]
}

// Pure region-membership operations for AgentsPanel's split-view state above. Pulled out of the
// view so "which region does a click select/grow" is unit-testable without a SwiftUI view harness
// (ManagementView.swift itself imports GhosttyTerminal, so it can't compile in a standalone
// swiftc test) — AgentsPanel's selectOrSwitch/addToSplit are thin @State wrappers that just call
// into these and write the result back.
enum AgentRegionLogic {
    static func regionIndex(containing stableID: String, in regions: [AgentRegion]) -> Int? {
        regions.firstIndex { $0.memberIDs.contains(stableID) }
    }

    struct SelectResult {
        var regions: [AgentRegion]
        var viewedRegionID: UUID
        var focusedStableID: String
    }

    // Plain click on a row: switch which region is VIEWED. If the agent is already part of a
    // region (lone or grouped), that whole region becomes the viewed one. Otherwise it opens as
    // its own new, separate region — this never touches an existing group's membership.
    static func selectOrSwitch(to stableID: String, regions: [AgentRegion]) -> SelectResult {
        if let idx = regionIndex(containing: stableID, in: regions) {
            return SelectResult(regions: regions, viewedRegionID: regions[idx].id, focusedStableID: stableID)
        }
        var regions = regions
        let region = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: [stableID])
        regions.append(region)
        return SelectResult(regions: regions, viewedRegionID: region.id, focusedStableID: stableID)
    }

    struct AddToSplitResult {
        var regions: [AgentRegion]
        var viewedRegionID: UUID
        // nil means "no-op" (already in the viewed region) — the caller must leave its own
        // focusedStableID untouched, not overwrite it with the no-op target.
        var focusedStableID: String?
    }

    // No cap: always grows whichever region is currently VIEWED (evenly re-tiling all its
    // members), never nests or replaces. The chosen direction only matters the first time a lone
    // agent becomes a real split; an existing multi-member region keeps its original direction.
    static func addToSplit(
        _ stableID: String, direction: Axis, regions: [AgentRegion], viewedRegionID: UUID?
    ) -> AddToSplitResult {
        guard let viewedRegionID else {
            // Nothing viewed yet. Already open in some other lingering region? Switch to viewing
            // that instead of duplicating it; otherwise it becomes a new region and the view.
            if let existingIdx = regionIndex(containing: stableID, in: regions) {
                return AddToSplitResult(regions: regions, viewedRegionID: regions[existingIdx].id, focusedStableID: stableID)
            }
            var regions = regions
            let region = AgentRegion(id: UUID(), direction: direction, memberIDs: [stableID])
            regions.append(region)
            return AddToSplitResult(regions: regions, viewedRegionID: region.id, focusedStableID: stableID)
        }

        var regions = regions
        let viewedRegion = regions.first { $0.id == viewedRegionID }
        guard !(viewedRegion?.memberIDs.contains(stableID) ?? false) else {
            return AddToSplitResult(regions: regions, viewedRegionID: viewedRegionID, focusedStableID: nil)
        }
        // Already open in a DIFFERENT region — move it here instead of duplicating it.
        if let oldIdx = regionIndex(containing: stableID, in: regions) {
            regions[oldIdx].memberIDs.removeAll { $0 == stableID }
            if regions[oldIdx].memberIDs.isEmpty {
                regions.remove(at: oldIdx)
            }
        }
        guard let idx = regions.firstIndex(where: { $0.id == viewedRegionID }) else {
            return AddToSplitResult(regions: regions, viewedRegionID: viewedRegionID, focusedStableID: nil)
        }
        if regions[idx].memberIDs.count == 1 {
            regions[idx].direction = direction
        }
        regions[idx].memberIDs.append(stableID)
        return AddToSplitResult(regions: regions, viewedRegionID: viewedRegionID, focusedStableID: stableID)
    }
}
