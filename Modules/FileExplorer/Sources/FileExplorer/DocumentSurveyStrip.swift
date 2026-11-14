import Design
import SwiftUI

/// One line under Organize's header saying that documents are being read, on every lens. The
/// survey is an hours-long background job and its card lives on the overview, so this lets someone
/// in Duplicates or Renames see it and pause it without leaving.
///
/// The card's own words and verbs: ``DocumentSurveyCardText`` is the source of both, so the two
/// can't describe one run differently.
public struct DocumentSurveyStrip: View {
    let state: DocumentSurveyCardState
    /// The hue the user picked, for the reading wash — the card's `accent`, so the two agree.
    let accent: Color
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    public init(state: DocumentSurveyCardState,
                accent: Color,
                onResume: (() -> Void)? = nil,
                onPause: (() -> Void)? = nil,
                onStop: (() -> Void)? = nil) {
        self.state = state
        self.accent = accent
        self.onResume = onResume
        self.onPause = onPause
        self.onStop = onStop
    }

    /// The three states the strip appears for: a run in flight. `.offered` belongs on the card,
    /// with room to say what it costs; `.finished` and `.settled` are receipts, and on every lens
    /// they would be a banner nobody can dismiss.
    public static func isShown(for state: DocumentSurveyCardState?) -> Bool {
        switch state {
        case .running, .finishing, .interrupted: return true
        default: return false
        }
    }

    public var body: some View {
        if Self.isShown(for: state) {
            HStack(spacing: 8) {
                if case .interrupted = state {
                    Image(systemName: "pause.circle")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    InlineSpinner()
                }
                Text(DocumentSurveyCardText.title(for: state))
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Text(DocumentSurveyCardText.detail(for: state))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                verbButtons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(background)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(DocumentSurveyCardText.title(for: state)). "
                                + DocumentSurveyCardText.detail(for: state))
        }
    }

    /// Accent while reading, grey while paused or interrupted: the card's rule.
    private var background: some ShapeStyle {
        switch state {
        case .interrupted:
            return AnyShapeStyle(Color.secondary.opacity(0.10))
        case .running(_, _, _, _, let pause) where pause != nil:
            return AnyShapeStyle(Color.secondary.opacity(0.10))
        default:
            return AnyShapeStyle(accent.opacity(0.10))
        }
    }

    private var verbButtons: some View {
        ForEach(verbs) { verb in
            strip(verb.title, help: verb.help, action: verb.run)
        }
    }

    /// The strip's verbs, as the card's ``OverviewCardAction``, so a test can compare the two
    /// without mounting either. `rank` is unused: they are drawn in order, all alike. Only verbs
    /// the card offers in the same state, with its tooltips: the strip may leave one out, never
    /// add one.
    var verbs: [OverviewCardAction] {
        var actions: [OverviewCardAction] = []
        switch state {
        case .running(_, _, _, _, let pause):
            if pause == nil, let onPause {
                actions.append(OverviewCardAction(title: "Pause", run: onPause))
            } else if let pause, pause.resumesOnItsOwn, let onResume {
                // The card's word: it reads through a pause that would clear by itself, rather
                // than undoing a Pause.
                actions.append(OverviewCardAction(title: "Resume Now",
                                                  help: DocumentSurveyCard.resumeNowHelp,
                                                  run: onResume))
            } else if let onResume {
                actions.append(OverviewCardAction(title: "Resume", run: onResume))
            }
            if let onStop {
                actions.append(OverviewCardAction(title: "Stop",
                                                  help: "Stop reading — what’s been read so far is kept",
                                                  run: onStop))
            }
        case .interrupted:
            if let onResume {
                actions.append(OverviewCardAction(title: "Resume",
                                                  help: "Carry on reading — only the documents not yet read",
                                                  run: onResume))
            }
            // No Stop: `stopDocumentSurvey()` stops the run in flight, and there is none. No
            // Start over either: it throws hours of reading away behind a question, which belongs
            // on the overview card, not on every lens.
        default:
            break
        }
        return actions
    }

    @ViewBuilder
    private func strip(_ title: String, help: String? = nil,
                       action: @escaping () -> Void) -> some View {
        let button = Button(title, action: action)
            .buttonStyle(.hoverAffordance(.inline))
            .scaledFont(.system(size: 11))
        if let help { button.help(help) } else { button }
    }
}
