import SwiftUI

/// A tiny visual indicator showing whether a given String path actually exists as a directory on disk.
public struct StatusBadge: View {
    public let isValid: Bool
    
    public init(isValid: Bool) {
        self.isValid = isValid
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isValid ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            
            Text(isValid ? "Valid path" : "Invalid path")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isValid ? .green : .red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((isValid ? Color.green : Color.red).opacity(PillVariant.fillOpacity))
        .clipShape(Capsule())
    }
}
