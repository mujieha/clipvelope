import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// An LSUIElement app cannot become frontmost, so its Settings window opens
/// behind whatever the user is looking at -- it is on screen, just invisible in
/// practice. `orderFrontRegardless` raises a window without activation, which is
/// the only thing that works for an agent app.
private func bringSettingsWindowForward() {
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows where window.canBecomeMain {
        // Otherwise macOS restores the window at the next launch, and a menu bar
        // app that opens Preferences by itself at login looks broken.
        window.isRestorable = false
        window.orderFrontRegardless()
        window.makeKey()
    }
}

struct PreferencesButton: View {
    var body: some View {
        SettingsLink {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                Text("Preferences")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        // Raise on every click, not just the first. PreferencesView's onAppear
        // does not fire again when the window is already open, so a second click
        // would otherwise look like it did nothing while the window sat behind
        // whatever the user was looking at.
        .simultaneousGesture(TapGesture().onEnded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bringSettingsWindowForward()
            }
        })
    }
}

/// The menu bar icon. It is also the one view that exists for as long as the
/// app runs, which makes it the place to answer `Clipvelope --preferences`: the
/// Settings scene opens through SwiftUI's own action, and that action only
/// exists inside a view's environment.
struct StatusItemLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // lock.doc rather than doc.on.clipboard, so the menu bar echoes the app
        // icon: a document that is locked, not two sheets of paper.
        Label("Clipvelope", systemImage: "lock.doc")
            .onReceive(DistributedNotificationCenter.default()
                .publisher(for: Diagnostics.preferencesNotification)) { _ in
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    bringSettingsWindowForward()
                }
            }
    }
}

/// A button that shows a shortcut as words and records a new one when clicked.
struct HotkeyRecorder: View {
    let combo: KeyCombo
    let defaultCombo: KeyCombo
    let onChange: (KeyCombo) -> Void
    /// Called with true while listening, so the caller can get a live global
    /// hotkey out of the way -- otherwise pressing the current combination is
    /// swallowed by the system before it reaches this window.
    var onRecordingChanged: ((Bool) -> Void)? = nil

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Press the new shortcut…" : combo.displayName) {
                recording ? stop() : start()
            }
            .help(recording ? "Escape cancels." : "Click, then press the keys you want.")
            if recording {
                Button("Cancel") { stop() }
                    .buttonStyle(.borderless)
            } else if combo != defaultCombo {
                Button("Reset") { onChange(defaultCombo) }
                    .buttonStyle(.borderless)
                    .help("Back to \(defaultCombo.displayName)")
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                   .isDisjoint(with: [.command, .shift, .option, .control]) {
                stop()
                return nil
            }
            // A key without a modifier is typing, not a shortcut; keep listening.
            guard let combo = KeyCombo(event: event) else { return nil }
            onChange(combo)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        onRecordingChanged?(false)
    }
}

/// A key hint drawn the way menus draw them: quiet until you need it.
struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}

struct StorageFailureBanner: View {
    let failure: StorageFailure
    @ObservedObject var store: ClipboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Saving paused").bold()
            }
            .font(.system(size: 12))
            .foregroundColor(.orange)

            Text(failure.message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Try Again") { store.retryLoadingVault() }
                Button("Start Fresh") { store.discardUnreadableVault() }
                    .help("Moves the unreadable vault aside so it can be recovered later.")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - History row

struct HistoryRow: View {
    let item: ClipboardItem
    /// Position in the displayed list; the first nine get a ⌘-number shortcut.
    let index: Int
    /// The row the arrow keys have reached; Return copies it.
    let isSelected: Bool
    @ObservedObject var store: ClipboardStore
    let onCopy: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    private var kindSymbol: String {
        switch item.content {
        case .text, .richText: return "text.alignleft"
        case .image: return "photo"
        case .files(let refs): return refs.count > 1 ? "doc.on.doc" : "doc"
        }
    }

    /// The source app's icon when it is known; otherwise what kind of thing this
    /// is. The list reads as "where things came from", which is how people
    /// remember them.
    @ViewBuilder
    private var gutter: some View {
        if let source = item.sourceBundleID,
           let icon = AppNameResolver.icon(forBundleID: source) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: kindSymbol)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func textLabel(_ summary: PreviewText.Summary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.text.isEmpty ? "Whitespace only" : summary.text)
                .font(.system(size: 13))
                .foregroundColor(summary.text.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if summary.lineCount > 1 {
                Text("\(summary.lineCount) lines")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch item.content {
        case .text(let value):
            textLabel(PreviewText.summary(of: value))

        case .richText(let info):
            // Plain and formatted text look the same here because to the user
            // they are the same thing; the tooltip says which this is.
            textLabel(PreviewText.summary(of: info.plainText))

        case .image(let info):
            HStack(spacing: 8) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 44, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Image")
                        .font(.system(size: 13))
                    Text("\(info.pixelWidth) × \(info.pixelHeight), "
                         + ByteCountFormatter.string(fromByteCount: Int64(info.byteCount),
                                                     countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

        case .files(let refs):
            VStack(alignment: .leading, spacing: 1) {
                Text(refs.map(\.name).joined(separator: ", "))
                    .lineLimit(1)
                    .font(.system(size: 13))
                // The path, not just a count: what gets pasted is the path,
                // so it is the thing worth showing.
                Text(refs.count == 1 ? refs[0].path : "\(refs.count) files")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tooltip: String {
        var lines: [String] = []
        if case .richText(let info) = item.content {
            lines.append(info.typeIdentifier == "public.html" ? "Formatted text (HTML)"
                                                              : "Formatted text (RTF)")
        }
        if let source = item.sourceBundleID {
            lines.append("Copied from \(AppNameResolver.displayName(forBundleID: source))")
        }
        lines.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        return lines.joined(separator: "\n")
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            HStack(spacing: 10) {
                gutter.frame(width: 18)
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            // Thumbnails are read from the payload file on demand and cached by
            // the store, so the index stays small.
            store.thumbnail(for: item) { thumbnail = $0 }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            Button(action: { store.togglePin(item) }) {
                Image(systemName: item.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(item.isPinned ? "Unpin" : "Pin")

            Button(action: { store.remove(item) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Delete")
        } else if isSelected {
            KeyBadge(text: "↩")
        } else if index < 9 {
            KeyBadge(text: "⌘\(index + 1)")
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            // SwiftUI scopes .keyboardShortcut to the containing window, so the
            // ⌘-number hints work in the menu without an app-wide event monitor
            // that would also fire in the Preferences window.
            if index < 9 {
                copyButton.keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command
                )
            } else {
                copyButton
            }
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

// MARK: - State strip

/// One line that says what the vault is doing right now. It replaces a stack
/// of differently coloured banners, so there is exactly one place to look.
struct StateStrip: View {
    @ObservedObject var store: ClipboardStore

    private var content: StripContent {
        StripContent.describe(isLoading: store.isLoading,
                              savingPaused: store.storageFailure != nil,
                              capturePaused: store.captureSuspended,
                              recordingPasswords: !store.skipConcealedContent,
                              itemCount: store.items.count,
                              notice: store.notice)
    }

    var body: some View {
        let content = content
        HStack(spacing: 6) {
            Image(systemName: content.symbol)
                .font(.system(size: 10))
            Text(content.text)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(content.degraded ? .orange : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(content.degraded ? Color.orange.opacity(0.12)
                                     : Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - The panel

struct ClipboardMenuView: View {
    @ObservedObject var store: ClipboardStore
    /// Search text and selection; the rules live in PanelModel, where a test
    /// can reach them.
    @State private var panel = PanelModel()
    @State private var contentHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private func closeMenuBarWindow() {
        NSApplication.shared.keyWindow?.close()
    }

    private var groups: [HistorySection.Group] { panel.groups(in: store.items) }
    private var visibleItems: [ClipboardItem] { groups.flatMap(\.items) }
    private var autocompleteSuggestion: String? { panel.suggestion(in: store.items) }

    private var queryBinding: Binding<String> {
        Binding(get: { panel.query }, set: { panel.setQuery($0) })
    }

    // MARK: Keyboard

    private func move(_ delta: Int) {
        panel.move(delta, rowCount: visibleItems.count)
    }

    private func copySelected() {
        guard let item = panel.selectedItem(in: store.items) else { return }
        store.copyToPasteboard(item)
        closeMenuBarWindow()
    }

    private func escape() {
        if panel.escape() == .close { closeMenuBarWindow() }
    }

    private func showPreferences() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            bringSettingsWindowForward()
        }
    }

    /// An AppKit alert rather than SwiftUI's `.alert`: the popover closes the
    /// moment anything else becomes key, which took the SwiftUI alert down with
    /// it before either button could act. This closes the panel first, then asks.
    private func confirmClear() {
        closeMenuBarWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete all clipboard history?"
            alert.informativeText = "Every item goes, pinned ones too, along with the "
                + "auto-backup file. This cannot be undone."
            alert.addButton(withTitle: "Cancel")
            let delete = alert.addButton(withTitle: "Delete Everything")
            delete.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                store.clearAll()
            }
        }
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            ZStack(alignment: .leading) {
                if let suggestion = autocompleteSuggestion {
                    Text(suggestion)
                        .foregroundColor(.secondary)
                        .opacity(0.4)
                        .lineLimit(1)
                }
                TextField("Search clipboard", text: queryBinding)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var listBody: some View {
        let items = visibleItems
        if store.isLoading {
            // Not the same as having no history, and saying so would be a claim
            // about the user's data made before reading it.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening vault…")
            }
            .foregroundColor(.secondary)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if items.isEmpty {
            Text(panel.query.isEmpty ? "Nothing copied yet.\nCopy something and it appears here."
                                     : "Nothing matches “\(panel.query)”.")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            let position = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
            ForEach(groups, id: \.section) { group in
                SectionLabel(title: group.section.title)
                ForEach(group.items) { item in
                    let index = position[item.id] ?? 0
                    HistoryRow(item: item, index: index, isSelected: index == panel.selection,
                               store: store) {
                        store.copyToPasteboard(item)
                        closeMenuBarWindow()
                    }
                    .id(item.id)
                }
            }
            Color.clear.frame(height: 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            PreferencesButton()

            Button(action: { store.setCaptureSuspended(!store.captureSuspended) }) {
                HStack(spacing: 4) {
                    Image(systemName: store.captureSuspended ? "play.circle" : "pause.circle")
                    Text(store.captureSuspended ? "Resume" : "Pause")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: confirmClear) {
                Text("Clear")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.items.isEmpty && store.storageFailure == nil)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = store.storageFailure {
                StorageFailureBanner(failure: failure, store: store)
                Divider()
            }

            searchBar
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    // Deliberately not a LazyVStack: a lazy stack cannot report a
                    // content height without a defined viewport, so under fixedSize
                    // it renders rows with no height. The list is capped at 50 rows,
                    // so laziness buys nothing anyway.
                    VStack(alignment: .leading, spacing: 0) {
                        listBody
                    }
                    // A ScrollView reports an ideal height of zero, and the
                    // MenuBarExtra window sizes itself to fit its content, so a bare
                    // `maxHeight` collapsed the list to nothing. `fixedSize` is the
                    // wrong cure: it makes the ScrollView ignore the size its parent
                    // offers, so rows overflow and paint over the search field.
                    // Measure the content and give the frame a definite height.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: min(max(contentHeight, 80), 420))
                // Without this the list shows the popover's vibrancy material, so the
                // desktop bleeds through behind the rows while the search field and
                // footer sit on a solid colour. Paint it to match them.
                .background(Color(NSColor.controlBackgroundColor))
                .onChange(of: panel.selection) {
                    guard let item = panel.selectedItem(in: store.items) else { return }
                    proxy.scrollTo(item.id)
                }
            }

            Divider()
            StateStrip(store: store)
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            PanelState.isOpen = true
            panel = PanelModel()
            // The popover window is created fresh each time the menu opens, so it
            // needs the appearance applied then, not only when the theme changes.
            AppearanceController.apply(store.themeMode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .onDisappear { PanelState.isOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: .clipvelopeOpen)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .background(MenuKeyHandler(query: queryBinding, suggestion: autocompleteSuggestion,
                                   preferencesCombo: store.preferencesHotkey,
                                   onMove: move, onSubmit: copySelected, onEscape: escape,
                                   onPreferences: showPreferences))
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var updater: UpdaterController
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: 0) {
                GeneralPane(store: store, updater: updater)
            }
            Tab("Privacy", systemImage: "hand.raised", value: 4) {
                PrivacyPane(store: store)
            }
            Tab("Quick Slots", systemImage: "command", value: 1) {
                QuickSlotsPane(store: store)
            }
            Tab("Folders", systemImage: "folder", value: 2) {
                FoldersPane(store: store)
            }
            Tab("Backup", systemImage: "externaldrive", value: 3) {
                BackupPane(store: store)
            }
        }
        // Fixed rather than resizable because a min/ideal/max frame made SwiftUI
        // take the maximum width and the minimum height, which is the worst of
        // both - long lines, still clipped. The forms scroll when they need to.
        .frame(width: 520, height: 520)
        .onAppear {
            // Deferred: the window is not in NSApp.windows yet during onAppear.
            DispatchQueue.main.async { bringSettingsWindowForward() }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var updater: UpdaterController
    @State private var launchAtLoginEnabled: Bool = false
    @State private var loginItemError: String?

    private static var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.themeMode) {
                    Text("System").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: store.themeMode) { store.persistState() }
            }

            Section {
                Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, enabled in
                        // Registration fails for an unbundled binary; revert
                        // rather than showing a toggle that lies.
                        if let error = LoginItemController.setEnabled(enabled) {
                            loginItemError = error.localizedDescription
                            launchAtLoginEnabled = LoginItemController.isEnabled()
                        } else {
                            loginItemError = nil
                        }
                    }
                    .onAppear { launchAtLoginEnabled = LoginItemController.isEnabled() }
                if let loginItemError {
                    Text(loginItemError).foregroundColor(.red)
                }
            } header: {
                Text("System")
            }

            Section {
                LabeledContent("Open history") {
                    HotkeyRecorder(combo: store.openHotkey, defaultCombo: .defaultOpen,
                                   onChange: { store.setOpenHotkey($0) },
                                   onRecordingChanged: { store.suspendOpenHotkey($0) })
                }
                if !store.openHotkeyRegistered {
                    Label("Another app already uses \(store.openHotkey.displayName), so it "
                          + "does nothing here. Choose a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                LabeledContent("Open Preferences") {
                    HotkeyRecorder(combo: store.preferencesHotkey, defaultCombo: .defaultPreferences,
                                   onChange: { store.setPreferencesHotkey($0) })
                }
                LabeledContent("Quick Slots", value: "Option + 1 to 9")
                LabeledContent("Copy an item", value: "Up and Down, then Return")
                LabeledContent("Copy one of the first nine", value: "Command + 1 to 9")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Open history and the Quick Slots work from any app; the others work "
                     + "while the history is open. Click a shortcut to change it.")
            }

            Section {
                LabeledContent("Version", value: Self.versionSummary)
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("About")
            } footer: {
                if updater.isAvailable {
                    Text("Clipvelope checks once a day and tells you when there is a new "
                         + "version. Updates are signed; one that is not signed by this "
                         + "developer is refused.")
                } else {
                    Text("This build does not check for updates.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyPane: View {
    @ObservedObject var store: ClipboardStore
    @State private var confirmSensitiveCapture = false

    private func chooseAppToIgnore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { result in
            guard result == .OK,
                  let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            store.ignoreApp(bundleID: bundleID)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Pause capturing", isOn: Binding(
                    get: { store.captureSuspended },
                    set: { store.setCaptureSuspended($0) }
                ))
            } header: {
                Text("Capture")
            } footer: {
                Text("Nothing new is recorded while paused. Existing history is kept.")
            }

            Section {
                // Phrased as the thing being switched on, not as a protection
                // being switched off. Un-ticking a safeguard reads as tidying
                // up; turning on "capture passwords" does not.
                Toggle("Capture passwords and other sensitive content", isOn: Binding(
                    get: { !store.skipConcealedContent },
                    set: { wantsCapture in
                        if wantsCapture {
                            confirmSensitiveCapture = true
                        } else {
                            store.setSkipConcealedContent(true)
                        }
                    }
                ))
                if !store.skipConcealedContent {
                    Label("Passwords you copy are being written to your history. It is "
                          + "encrypted, but anything in it can be copied back out, and it "
                          + "is included in backups.",
                          systemImage: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Sensitive content")
            } footer: {
                Text("Password managers mark copied credentials, one-time codes and API "
                     + "tokens so apps like this one can leave them alone. Clipvelope "
                     + "skips them by default.")
            }

            Section {
                if store.isKeyIsolated {
                    Label("The encryption key is private to Clipvelope.",
                          systemImage: "checkmark.shield.fill")
                } else {
                    Label("This build is not signed, so the encryption key is stored where "
                          + "any app you run can read it. Your history is still encrypted "
                          + "on disk.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Key storage")
            } footer: {
                if !store.isKeyIsolated {
                    Text("Signing the app moves the key somewhere only Clipvelope can reach. "
                         + "See docs/SIGNING.md.")
                }
            }

            Section {
                if store.ignoredAppBundleIDs.isEmpty {
                    Text("No apps ignored.").foregroundColor(.secondary)
                }
                ForEach(store.ignoredAppBundleIDs, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppNameResolver.icon(forBundleID: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppNameResolver.displayName(forBundleID: bundleID))
                            Text(bundleID).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.stopIgnoringApp(bundleID: bundleID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop ignoring")
                    }
                }
                Button("Add App…", action: chooseAppToIgnore)
            } header: {
                Text("Ignored apps")
            } footer: {
                Text("Anything copied while one of these apps is frontmost is not recorded.")
            }
        }
        .formStyle(.grouped)
        .alert("Record passwords in your clipboard history?",
               isPresented: $confirmSensitiveCapture) {
            Button("Cancel", role: .cancel) { }
            Button("Record Them", role: .destructive) {
                store.setSkipConcealedContent(false)
            }
        } message: {
            Text("Password managers mark copied credentials so apps like this one can "
                 + "skip them. Turning this on stores them in your history, including "
                 + "one-time codes and API tokens.\n\nThe history is encrypted on disk, "
                 + "but anything in it can be copied back out, and it is included in "
                 + "any backup you export.")
        }
    }
}

private struct QuickSlotsPane: View {
    @ObservedObject var store: ClipboardStore

    /// Bindings into the array by index, guarded because a slot can be removed
    /// while a field bound to it is still on screen.
    private func title(_ index: Int) -> Binding<String> {
        Binding(
            get: { store.bindings.indices.contains(index) ? store.bindings[index].title : "" },
            set: { guard store.bindings.indices.contains(index) else { return }
                   store.bindings[index].title = $0; store.persistState() }
        )
    }

    private func content(_ index: Int) -> Binding<String> {
        Binding(
            get: { store.bindings.indices.contains(index) ? store.bindings[index].content : "" },
            set: { guard store.bindings.indices.contains(index) else { return }
                   store.bindings[index].content = $0; store.persistState() }
        )
    }

    private func isShell(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { store.bindings.indices.contains(index) ? store.bindings[index].isShell : false },
            set: { guard store.bindings.indices.contains(index) else { return }
                   store.bindings[index].isShell = $0; store.persistState() }
        )
    }

    var body: some View {
        Form {
            if store.bindings.isEmpty {
                Section {
                    Text("No slots yet.").foregroundColor(.secondary)
                } footer: {
                    Text("A slot is a text snippet, or a shell command whose output is "
                         + "copied. Press ⌥ and the slot's number from any app.")
                }
            }
            ForEach(Array(store.bindings.enumerated()), id: \.element.id) { index, binding in
                Section {
                    if store.unavailableSlots.contains(index + 1) {
                        Label("Another app already uses Option + \(index + 1), so this slot "
                              + "cannot fire. Quit or reconfigure that app, then relaunch Clipvelope.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    TextField("Label", text: title(index))
                    TextField(binding.isShell ? "Shell command" : "Text snippet",
                              text: content(index))
                    Toggle("Run as a shell command", isOn: isShell(index))
                } header: {
                    HStack {
                        Text("⌥\(index + 1)")
                        Spacer()
                        Button(role: .destructive) {
                            store.removeBinding(binding)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove slot")
                    }
                }
            }
            Section {
                Button("Add Slot") { store.addBinding() }
                    .disabled(store.bindings.count >= 9)
            } footer: {
                if store.bindings.count >= 9 {
                    Text("Nine slots is the limit: there are nine digits.")
                } else if !store.bindings.isEmpty {
                    Text("A shell command runs with your login shell and its output is "
                         + "copied. Slots imported from a portable backup arrive with this "
                         + "switched off.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FoldersPane: View {
    @ObservedObject var store: ClipboardStore
    @State private var selectedFolderID: UUID? = nil
    @State private var newFolderName: String = ""

    private var selectedFolder: CommandFolder? {
        guard let id = selectedFolderID else { return nil }
        return store.folders.first(where: { $0.id == id })
    }

    private func update(_ folderID: UUID, _ change: (inout CommandFolder) -> Void) {
        guard let index = store.folders.firstIndex(where: { $0.id == folderID }) else { return }
        change(&store.folders[index])
        store.persistState()
    }

    private func updateItem(_ folderID: UUID, _ itemID: UUID,
                            _ change: (inout CommandItem) -> Void) {
        update(folderID) { folder in
            guard let index = folder.items.firstIndex(where: { $0.id == itemID }) else { return }
            change(&folder.items[index])
        }
    }

    var body: some View {
        Form {
            if let folder = selectedFolder {
                Section {
                    HStack {
                        TextField("Folder name", text: Binding(
                            get: { folder.name },
                            set: { name in update(folder.id) { $0.name = name } }
                        ))
                        Button(role: .destructive) {
                            store.removeFolder(folder)
                            selectedFolderID = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete folder")
                    }
                } header: {
                    Button {
                        selectedFolderID = nil
                    } label: {
                        Label("All folders", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(folder.items) { item in
                    Section {
                        TextField("Label", text: Binding(
                            get: { item.title },
                            set: { value in updateItem(folder.id, item.id) { $0.title = value } }
                        ))
                        TextField(item.isShell ? "Shell command" : "Text snippet", text: Binding(
                            get: { item.content },
                            set: { value in updateItem(folder.id, item.id) { $0.content = value } }
                        ))
                        Toggle("Run as a shell command", isOn: Binding(
                            get: { item.isShell },
                            set: { value in updateItem(folder.id, item.id) { $0.isShell = value } }
                        ))
                        HStack {
                            Button(item.isShell ? "Run and Copy Output" : "Copy") {
                                if item.isShell { store.runShellAndCopy(item.content) }
                                else { store.copyText(item.content) }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeCommand(folder: folder, item: item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }

                Section {
                    Button("Add Command") { store.addCommand(to: folder) }
                }
            } else {
                Section {
                    if store.folders.isEmpty {
                        Text("No folders yet.").foregroundColor(.secondary)
                    }
                    ForEach(store.folders) { folder in
                        Button {
                            selectedFolderID = folder.id
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                Text(folder.items.count == 1 ? "1 command"
                                                             : "\(folder.items.count) commands")
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("A folder groups snippets and commands you run by hand rather "
                         + "than from a hotkey.")
                }

                Section {
                    HStack {
                        TextField("New folder name", text: $newFolderName)
                            .onSubmit(addFolder)
                        Button("Add Folder", action: addFolder)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.folders.append(CommandFolder(id: UUID(),
                                           name: name.isEmpty ? "New Folder" : name,
                                           items: []))
        store.persistState()
        newFolderName = ""
    }
}

private struct BackupPane: View {
    @ObservedObject var store: ClipboardStore
    @State private var backupPassword: String = ""
    @State private var autoBackupPasswordSaved = false

    var body: some View {
        Form {
            if let notice = store.importNotice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }

            Section {
                HStack {
                    Button("Export…") { store.manualExportKeychain() }
                    Button("Import…") { store.manualImportKeychain() }
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Encrypted with the key in this Mac's Keychain. These files cannot be "
                     + "opened on another Mac.")
            }

            Section {
                SecureField("Backup password", text: $backupPassword)
                HStack {
                    Button("Export…") { store.manualExportPassword(backupPassword) }
                        .disabled(backupPassword.isEmpty)
                    Button("Import…") { store.manualImportPassword(backupPassword) }
                        .disabled(backupPassword.isEmpty)
                }
            } header: {
                Text("Portable")
            } footer: {
                Text("Encrypted with a password you choose, so the file can be restored on "
                     + "any Mac. Importing one switches off the shell flag on every command "
                     + "it contains, and never weakens your privacy settings.")
            }

            Section {
                Toggle("Back up automatically", isOn: $store.autoBackupEnabled)
                    .onChange(of: store.autoBackupEnabled) { store.persistState() }

                if store.autoBackupEnabled {
                    Picker("Protect with", selection: $store.autoBackupMode) {
                        Text("Keychain").tag(BackupMode.keychain)
                        Text("Password").tag(BackupMode.password)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.autoBackupMode) { store.persistState() }

                    if store.autoBackupMode == .password {
                        HStack {
                            Button("Use the Password Above") {
                                store.saveAutoBackupPassword(backupPassword)
                                autoBackupPasswordSaved = true
                            }
                            .disabled(backupPassword.isEmpty)
                            if autoBackupPasswordSaved {
                                Text("Saved to Keychain").foregroundColor(.secondary)
                            }
                        }
                    }

                    Button("Restore from Auto Backup…") {
                        store.restoreFromAutoBackup(
                            password: store.autoBackupMode == .password ? backupPassword : nil
                        )
                    }
                    .disabled(store.autoBackupMode == .password && backupPassword.isEmpty)
                }
            } header: {
                Text("Auto backup")
            } footer: {
                Text("Writes ~/Documents/Clipvelope/clipvelope-backup.cvb after every change.")
            }
        }
        .formStyle(.grouped)
    }
}
