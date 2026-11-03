import AppKit
import PureMouseAppSupport
import SwiftUI

extension Notice {
    /// Multicolour where the symbol has colours of its own (docs/ui-design.md).
    var symbol: String {
        switch self {
        case .configError: "xmark.octagon.fill"
        case .off, .paused: "pause.circle.fill"
        case .noMouse: "computermouse"
        case .writeError, .statusTooNew, .inputMonitoring, .logiOptions, .accessibility: "exclamationmark.triangle.fill"
        }
    }

    @MainActor func title(_ model: AppModel) -> String {
        switch self {
        case .configError: "The config file isn't valid."
        case .writeError: "That change wasn't saved."
        case .statusTooNew: "PureMouse needs an update."
        case .off: "PureMouse is off."
        case .paused: "PureMouse is paused."
        case .inputMonitoring: Self.inputMonitoringTitle(waiting: model.waitingForInputMonitoring.map(\.name))
        case .logiOptions: "Logi Options+ is running."
        case .accessibility: "PureMouse needs Accessibility."
        case .noMouse: "No mouse found."
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
        case .inputMonitoring:
            Self.inputMonitoringMessage(waiting: model.waitingForInputMonitoring.map(\.name))
        case .noMouse: "Turn on your mouse or plug in its receiver."
        case .logiOptions: "Only one app can control the buttons. Quit Logi Options+, then remove it from Login Items so it stays quit."
        case .accessibility:
            "PureMouse can't scroll smoothly or press shortcuts until you allow it in System Settings. It restarts itself once you do."
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
    /// False above a bare empty state, where there is no form to put the banner in.
    var inForm = true

    var body: some View {
        // A pane that has no mouse to show says so in place (docs/ui-design.md, empty states).
        let notices = BannerPlan.items(for: BannerPlan.State(model: model, needsAccessibility: needsAccessibility))
            .filter { $0 != .noMouse }
        if let notice = notices.first {
            let banner = Banner(title: notice.title(model), message: notice.message(model), symbol: notice.symbol,
                                more: BannerPlan.moreText(notices.count - 1), showMore: { settings?.open(.tab(.general)) },
                                actions: { NoticeActions(notice: notice) }, link: { NoticeLink(notice: notice) })
            if inForm {
                Section { banner }
            } else {
                banner.padding(.horizontal, 30).padding(.top, 20)
            }
        }
    }
}

/// The save-failure notice inside a sheet, which covers the pane's own banner: the same `Banner`
/// as `PaneBanners`, for the one notice a change made in the sheet can raise.
struct SheetBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.writeError != nil {
            let notice = Notice.writeError
            Section {
                Banner(title: notice.title(model), message: notice.message(model), symbol: notice.symbol) {
                    NoticeActions(notice: notice)
                }
            }
        }
    }
}

/// A notice at the top of a pane: its title with its symbol, the message under it, and its buttons
/// to the side, with a link to the rest in General. A row of its own, since `LabeledContent` would
/// squeeze a long message beside the buttons. The symbol sits in the title's line, so the message
/// starts at the form's own text edge. General's rows and the Apps tab's suggestion use it too.
struct Banner<Actions: View, Link: View>: View {
    let title: String
    let message: String
    var symbol = "exclamationmark.triangle.fill"
    /// "2 more notices", which runs `showMore`.
    var more: String?
    var showMore: () -> Void = {}
    @ViewBuilder var actions: Actions
    /// A link-style button under the message.
    @ViewBuilder var link: Link

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(title).fontWeight(.semibold)
                } icon: {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .accessibilityHidden(true)
                }
                Text(message).foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                link
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

extension Banner where Link == EmptyView {
    init(title: String, message: String, symbol: String = "exclamationmark.triangle.fill", more: String? = nil,
         showMore: @escaping () -> Void = {}, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, message: message, symbol: symbol, more: more, showMore: showMore,
                  actions: actions, link: { EmptyView() })
    }
}

/// A notice as a row of General's Status section: the same banner, in the form.
struct NoticeRow: View {
    @Environment(AppModel.self) private var model
    let notice: Notice

    var body: some View {
        Banner(title: notice.title(model), message: notice.message(model), symbol: notice.symbol,
               actions: { NoticeActions(notice: notice) }, link: { NoticeLink(notice: notice) })
    }
}

/// The link-style button some notices carry under their message.
struct NoticeLink: View {
    let notice: Notice

    var body: some View {
        if let action = notice.logiOptionsLink, let url = action.url {
            // Drawn as a link, but a plain button: the link style's frame is its text's 15 pt, and
            // the padding inside the label gives the button a hit target of at least 20 pt.
            Button { NSWorkspace.shared.open(url) } label: {
                Text(action.title).foregroundStyle(.link).padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
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
            Button(LogiOptionsAction.quit.title) { LogiOptionsQuit.shared.ask { model.askDaemonToRecheck() } }
        case .accessibility:
            Button("Allow Accessibility…") { NSWorkspace.shared.open(PrivacyPane.accessibility.url) }
                .accessibilityLabel("Allow Accessibility…, opens System Settings")
        case .inputMonitoring:
            Button("Allow Input Monitoring…") { NSWorkspace.shared.open(PrivacyPane.inputMonitoring.url) }
                .accessibilityLabel("Allow Input Monitoring…, opens System Settings")
        case .noMouse:
            EmptyView()
        }
    }
}
