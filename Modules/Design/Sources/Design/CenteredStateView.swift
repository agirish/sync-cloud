import SwiftUI

/// The app's one empty/intro-state template: a large hierarchical symbol, a short title, a
/// supporting message capped at a readable width, then one accessory — usually a single
/// primary button. Grown from the Tidy duplicates pre-scan state (the strongest empty state
/// in the app: it names the provider, explains the job, and states the safety contract), and
/// promoted here so every other surface copies it instead of composing its own VStack.
public struct CenteredStateView<Accessory: View>: View {
    private let symbol: String
    private let tint: Color
    private let title: String
    private let message: String
    private let accessory: Accessory

    public init(
        symbol: String, tint: Color, title: String, message: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            accessory
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

public extension CenteredStateView where Accessory == EmptyView {
    /// States with no honest action to offer — a button for the button's sake would dilute
    /// the surfaces where the primary action means something.
    init(symbol: String, tint: Color, title: String, message: String) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}
