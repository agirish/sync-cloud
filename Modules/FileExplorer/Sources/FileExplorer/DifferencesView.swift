import Events
import SwiftUI
import Sync
import AppKit

/// Tracks Shift/Command so the differences list can offer “Move” instead of “Copy” when a modifier is held.
@MainActor
final class ModifierTracker: ObservableObject {
    @Published var isMoveModifierPressed: Bool = false
    nonisolated(unsafe) private var monitor: Any?
    
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateModifiers(event.modifierFlags)
            return event
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let isPressed = flags.contains(.shift) || flags.contains(.command)
        if isMoveModifierPressed != isPressed {
            isMoveModifierPressed = isPressed
        }
    }
}

/// List of all differences between the two panes with actions to copy or move each item left or right.
public struct DifferencesView: View {
    @ObservedObject public var syncManager: FileSyncManager
    @StateObject private var modifierTracker = ModifierTracker()
    
    public init(syncManager: FileSyncManager) {
        self.syncManager = syncManager
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Differences Found")
                    .font(.headline)
                Spacer()
                Text("\(syncManager.differences.count) files")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(syncManager.differences, id: \.id) { difference in
                        DifferenceRow(
                            difference: difference,
                            isMove: modifierTracker.isMoveModifierPressed
                        ) { isMove in
                            Task {
                                await syncManager.syncFile(difference, isMove: isMove)
                            }
                        }
                        .transition(.slide)
                    }
                }
                .padding()
            }
            .background(.ultraThinMaterial)
        }
    }
}

/// One row in the differences list: icon, path, description, and a button to sync (copy or move) the item.
struct DifferenceRow: View {
    let difference: FileDifference
    let isMove: Bool
    let onSync: (Bool) -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            iconForDifference(difference)
                .font(.system(size: 24))
                .foregroundColor(colorForDifference(difference))
                .frame(width: 32)
            
            // File Info
            VStack(alignment: .leading, spacing: 4) {
                let parts = difference.relativePath.split(separator: "/")
                if parts.count > 1 {
                    Text(parts.dropLast().joined(separator: " / "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(parts.last ?? "")
                    .fontWeight(.medium)
                
                Text(difference.description)
                    .font(.caption)
                    .foregroundColor(colorForDifference(difference))
            }
            
            Spacer()
            
            // Sync Action
            Button(action: { onSync(isMove) }) {
                HStack {
                    if difference.isSyncing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        switch difference.action {
                        case .copyToRight:
                            Label(isMove ? "Move to Right" : "Copy to Right", systemImage: "arrow.right.circle.fill")
                        case .copyToLeft:
                            Label(isMove ? "Move to Left" : "Copy to Left", systemImage: "arrow.left.circle.fill")
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(difference.action == .copyToRight ? .blue : .purple)
            .disabled(difference.isSyncing)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    @ViewBuilder
    private func iconForDifference(_ diff: FileDifference) -> some View {
        switch diff.type {
        case .missingOnRight:
            Image(systemName: "plus.circle.fill")
        case .missingOnLeft:
            Image(systemName: "plus.circle.fill")
        case .differentDates:
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
    
    private func colorForDifference(_ diff: FileDifference) -> Color {
        switch diff.type {
        case .missingOnRight:
            return .blue
        case .missingOnLeft:
            return .purple
        case .differentDates:
            return .orange
        }
    }
}
