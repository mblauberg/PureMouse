import AppKit
import PureMouseAppSupport
import SwiftUI

extension Notice {
    /// Multicolour where the symbol has colours of its own (docs/ui-design.md).
    var symbol: String {
        switch self {
        case .configError: "xmark.octagon.fill"
        case .off, .paused: "pause.circle.fill"
        case .writeError, .statusTooNew, .logiOptions, .accessibility: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .configError: "The config file isn't valid."
        case .writeError: "That change wasn't saved."
        case .statusTooNew: "PureMouse needs an update."
        case .off: "PureMouse is off."
        case .paused: "PureMouse is paused."
        case .logiOptions: "Logi Options+ is running."
        case .accessibility: "PureMouse needs Accessibility."
        }
    }

    @MainActor func message(_ model: AppModel) -> String {
        switch self {
        case .configError:
            (model.configError.map { $0 + "\n" } ?? "")
                + "PureMouse keeps using the last config that worked. Fix the file to edit settings here."
        case .writeError: model.writeError ?? ""
        case .statusTooNew: "The menu bar app is older than the PureMouse running now. Install the latest release."
        case .off: "The mouse works as it does without PureMouse. Changes here apply when it starts."
        case .paused: "The mouse works as it does without PureMouse. Changes here apply when it resumes."
        case .logiOptions: "Only one app can control the buttons. Quit Logi Options+ or remove it."
        case .accessibility:
            "Allow it in System Settings to use smooth scrolling and button actions. PureMouse restarts itself when you do."
        }
    }
}

/// The one notice at the top of a pane: the first that applies (`BannerPlan`), with a link to
/// General when more apply. General lists them as rows instead.
struct PaneBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    /// The pane's settings do nothing without Accessibility.
    var needsAccessibility = false

    var body: some View {
        let notices = BannerPlan.items(for: BannerPlan.State(model: model, needsAccessibility: needsAccessibility))
        if let notice = notices.first {
            Section {
                Banner(title: notice.title, message: notice.message(model), symbol: notice.symbol,
                       more: BannerPlan.moreText(notices.count - 1), showMore: { settings?.open(.tab(.general)) }) {
                    NoticeActions(notice: notice)
                }
            }
        }
    }
}

/// A notice at the top of a pane: its symbol, a title over its message, and its buttons, with a
/// link to the rest in General. A row of its own, since `LabeledContent` would squeeze a long
/// message beside the buttons. The Apps tab's suggestion uses it too.
struct Banner<Actions: View>: View {
    let title: String
    let message: String
    var symbol = "exclamationmark.triangle.fill"
    /// "2 more notices", which runs `showMore`.
    var more: String?
    var showMore: () -> Void = {}
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message).foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let more {
                    Button(more, action: showMore)
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityHint("Shows every notice in General")
                }
            }
            Spacer(minLength: 8)
            HStack { actions }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A notice as a row of General's Status section.
struct NoticeRow: View {
    @Environment(AppModel.self) private var model
    let notice: Notice

    var body: some View {
        LabeledContent {
            NoticeActions(notice: notice)
        } label: {
            Label {
                RowLabel(notice.title, help: notice.message(model))
            } icon: {
                Image(systemName: notice.symbol).symbolRenderingMode(.multicolor)
            }
        }
    }
}

/// A notice's buttons, the same on its banner and its row.
struct NoticeActions: View {
    @Environment(AppModel.self) private var model
    let notice: Notice
    @State private var confirmingLastWorking = false

    var body: some View {
        switch notice {
        case .configError:
            VStack(alignment: .trailing) {
                Button("Open Config File") { NSWorkspace.shared.open(model.locations.config) }
                if model.canRestoreLastWorking {
                    Button("Use Last Working Config…") { confirmingLastWorking = true }
                }
            }
            // It replaces the whole file, so it asks first.
            .confirmationDialog(UseLastWorkingConfirmation.title, isPresented: $confirmingLastWorking) {
                Button(UseLastWorkingConfirmation.button) { model.restoreLastWorking() }
            } message: {
                Text(UseLastWorkingConfirmation.message(backupName: model.backupName))
            }
        case .writeError:
            EmptyView()
        case .statusTooNew:
            Button("View Releases") { NSWorkspace.shared.open(Links.releases) }
        case .off:
            Button("Start PureMouse") { notice.loginAction.map { model.perform($0.command) } }
        case .paused:
            Button("Resume") { model.setPaused(false) }
        case .logiOptions:
            Button("Learn More") { NSWorkspace.shared.open(Links.logiOptions) }
        case .accessibility:
            Button("Open System Settings") { NSWorkspace.shared.open(PrivacyPane.accessibility.url) }
                .accessibilityLabel("Allow Accessibility in System Settings")
        }
    }
}
