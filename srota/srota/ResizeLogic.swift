import CoreGraphics

enum SidebarResizeLogic {
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 500

    static func updatedWidth(startWidth: CGFloat, translationWidth: CGFloat) -> CGFloat {
        max(minWidth, min(maxWidth, startWidth + translationWidth))
    }

    static func dividerThickness(sidebarVisible: Bool, isHovered: Bool) -> CGFloat {
        guard sidebarVisible else { return 0 }
        return isHovered ? 3 : 1
    }
}

enum PaneResizeLogic {
    static let minFraction: CGFloat = 0.1

    static func clampedDelta(
        startSizes: [CGFloat],
        negativeIndices: Set<Int>,
        translation: CGFloat,
        minimumFraction: CGFloat = minFraction
    ) -> CGFloat? {
        guard !startSizes.isEmpty else { return nil }

        var lowerBound: CGFloat = -.greatestFiniteMagnitude
        var upperBound: CGFloat = .greatestFiniteMagnitude

        for (index, size) in startSizes.enumerated() {
            if negativeIndices.contains(index) {
                lowerBound = max(lowerBound, minimumFraction - size)
            } else {
                upperBound = min(upperBound, size - minimumFraction)
            }
        }

        guard lowerBound <= upperBound else { return nil }
        return max(lowerBound, min(upperBound, translation))
    }
}
