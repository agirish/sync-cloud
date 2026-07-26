import SwiftUI

/// A tiny visual indicator showing whether a given String path actually exists as a directory on disk.
public struct StatusBadge: View {
    public let isValid: Bool
    
    public init(isValid: Bool) {
        self.isValid = isValid
    }
    
    /// Valid/invalid are meanings, not styles — paint them from the shared semantic table
    /// (C3) so "valid" here can never drift from "success" elsewhere.
    private var color: Color { isValid ? SemanticColor.success : SemanticColor.error }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            
            Text(isValid ? "Valid path" : "Invalid path")
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(PillVariant.fillOpacity))
        .clipShape(Capsule())
    }
}
