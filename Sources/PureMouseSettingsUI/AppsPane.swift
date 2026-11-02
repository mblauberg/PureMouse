import AppKit
import PureMouseAppSupport
import PureMouseKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-app settings (`apps.<bundle id>`): a list of apps, each opening its own buttons, thumb
/// wheel and scrolling in a sheet (`AppSheet`). Writes only the keys it shows under `apps`; a
/// setting put back to "Same as Everywhere" removes its key, and an app with nothing left is
/// removed (`ConfigTree.set`).
struct AppsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settings) private var settings
    @State private var list = AppList()
    @State private var identities = AppIdentities()
    /// The app whose Remove… was chosen from its row's context menu.
    @State private var removing: String?

    var body: some View {
        let apps = listed
        PaneForm {
            PaneBanners(needsAccessibility: true)
            Section {
                if apps.isEmpty {
                    ContentUnavailableView {
                        Label("No Apps", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Add an app to give it its own buttons, thumb wheel or scrolling.")
                    } actions: {
                        addMenu
                    }
                    // A form row sizes to its content and sits leading; the empty state centres in the row.
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(apps, id: \.self) { id in
                        AppRow(identity: identities.identity(id), summary: list.summary(id, in: model.config)) {
                            list.open = id
                        }
                        .contextMenu {
                            Button("Remove…") { removing = id }
                        }
                    }
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Buttons follow the app you're using.\nScrolling and the thumb wheel follow the app under the pointer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The empty state carries the only Add App.
                    if !apps.isEmpty { addMenu }
                }
            }
            .disabled(model.readOnly)
        }
        // A row added or removed changes the pane's height; opening an app does not.
        .onChange(of: apps.count) { settings?.refit() }
        .sheet(isPresented: Binding(get: { list.open != nil }, set: { if !$0 { list.open = nil } })) {
            if let key = list.open {
                AppSheet(key: key, identity: identities.identity(key)) { remove(key) }
                    .environment(model)
                    .environment(\.settings, settings)
            }
        }
        .removeAppAlert(name: removing.map { identities.identity($0).name } ?? "this app",
                        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let id = removing { remove(id) }
        }
        #if DEBUG
        .onAppear {
            if let id = ProcessInfo.processInfo.environment["PUREMOUSE_DEV_APP"] { list.add(id, in: model.config) }
        }
        #endif
    }

    /// The configured apps and those added here, by name.
    private var listed: [String] {
        list.ids(in: model.config).sorted {
            identities.identity($0).name.localizedStandardCompare(identities.identity($1).name) == .orderedAscending
        }
    }

    private var addMenu: some View {
        Menu("Add App") {
            Button("Choose from Applications…") { chooseApp() }
            let running = RunningApp.all(excluding: Set(listed.map { $0.lowercased() }))
            if !running.isEmpty {
                Section("Running") {
                    ForEach(running) { entry in
                        Button(entry.name) { list.add(entry.id, in: model.config) }
                    }
                }
            }
        }
        // A bordered pull-down, not a borderless one that reads as a link.
        .menuStyle(.button)
        .fixedSize()
        .accessibilityHint("Choose an app to give its own settings")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app to give its own buttons, thumb wheel or scrolling."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier else {
                let alert = AppList.cannotAdd(url)
                Alerts.show(alert.title, alert.message)
                return
            }
            list.add(id, in: model.config)
        }
        if let window = settings?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func remove(_ id: String) {
        model.update { list.remove(id, from: &$0) }
        removing = nil
    }
}

/// An app's name and where it is installed, looked up when the list first needs it and kept for
/// the pane's life (which ends when Settings closes). Icons are not: `AppIcon` loads one when it
/// appears on screen and lets it go with its row.
@MainActor
final class AppIdentities {
    struct Identity {
        let name: String
        let url: URL?
        var installed: Bool { url != nil }

        /// The app's icon, or the generic one when it is not installed.
        @MainActor
        func loadIcon() -> NSImage {
            url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        }
    }

    private var cache: [String: Identity] = [:]

    func identity(_ bundleID: String) -> Identity {
        let key = bundleID.lowercased()
        if let hit = cache[key] { return hit }
        let identity: Identity
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            identity = Identity(name: name, url: url)
        } else {
            identity = Identity(name: AppSuggestion.forApp(bundleID)?.name ?? bundleID, url: nil)
        }
        cache[key] = identity
        return identity
    }
}

/// A running app with a Dock icon, for the Add App menu (read when the pane draws, never watched).
private struct RunningApp: Identifiable {
    let id: String
    let name: String

    @MainActor
    static func all(excluding: Set<String>) -> [RunningApp] {
        var seen = excluding
        seen.insert((Bundle.main.bundleIdentifier ?? "").lowercased())
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, seen.insert(id.lowercased()).inserted else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// An app's icon, loaded when it first scrolls into view. A grouped form builds every row to
/// size the window, so `onAppear` alone would load the icons of rows below the fold too; this
/// checks the icon's frame against the scroll view's visible bounds instead (macOS 14 has no
/// `onScrollVisibilityChange`, so every version takes this one path).
struct AppIcon: View {
    let identity: AppIdentities.Identity
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onGeometryChange(for: Bool.self, of: Self.isVisible) { visible in
            if visible, image == nil { image = identity.loadIcon() }
        }
    }

    /// Whether any of the view is inside its scroll view's visible bounds (or there is no scroll
    /// view, so it shows).
    nonisolated static func isVisible(_ proxy: GeometryProxy) -> Bool {
        guard let visible = proxy.bounds(of: .scrollView) else { return true }
        return visible.intersects(CGRect(origin: .zero, size: proxy.size))
    }
}

private struct AppRow: View {
    let identity: AppIdentities.Identity
    let summary: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AppIcon(identity: identity, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.name)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.name)
        .accessibilityValue(summary)
        .accessibilityHint("Shows its settings")
        .accessibilityAddTraits(.isButton)
    }
}
