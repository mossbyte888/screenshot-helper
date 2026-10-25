import AppKit
import Carbon
import CoreGraphics

final class ScreenshotPreview: NSImageView {
    // A full-resolution screenshot must never become the window's minimum size.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

struct Shortcut: Equatable {
    var code: UInt32
    var modifiers: UInt32
    var key: String
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }
    static let defaults = [1: Shortcut(code: 19, modifiers: UInt32(controlKey | optionKey), key: "2"),
                           2: Shortcut(code: 20, modifiers: UInt32(controlKey | optionKey), key: "3")]
    static func load(_ id: Int) -> Shortcut {
        let d = UserDefaults.standard
        guard let value = d.dictionary(forKey: "shortcut.\(id)"),
              let code = value["code"] as? NSNumber,
              let mods = value["modifiers"] as? NSNumber,
              let key = value["key"] as? String else { return defaults[id]! }
        return Shortcut(code: code.uint32Value, modifiers: mods.uint32Value, key: key)
    }
    func save(_ id: Int) {
        UserDefaults.standard.set(["code": code, "modifiers": modifiers, "key": key], forKey: "shortcut.\(id)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var statusLabel = NSTextField(labelWithString: "准备就绪 · 截图后自动复制，不自动保存")
    var preview = ScreenshotPreview()
    var emptyLabel = NSTextField(labelWithString: "最近一次截图会显示在这里")
    var saveButton = NSButton()
    var copyButton = NSButton()
    var shortcutButtons: [Int: NSButton] = [:]
    var shortcuts = [1: Shortcut.load(1), 2: Shortcut.load(2)]
    var hotkeyRefs: [Int: EventHotKeyRef] = [:]
    var hotkeyHandler: EventHandlerRef?
    var captureProcess: Process?
    var recentPNG: Data?
    var recentImage: NSImage?
    var recording = false
    var localMonitor: Any?
    var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showNotification = NSNotification.Name("local.codex.screenshothelper.showWindow")
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.screenshothelper")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil,
                userInfo: nil, deliverImmediately: true)
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow),
            name: showNotification, object: nil)
        NSApp.setActivationPolicy(.regular)
        makeApplicationMenu()
        makeWindow()
        makeMenu()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.capture(Int(id.id)) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        for id in [1, 2] {
            if !register(id, shortcuts[id]!) { statusLabel.stringValue = "快捷键被占用，请在下方重新设置。" }
        }
        showWindow()
    }

    func register(_ id: Int, _ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.code, shortcut.modifiers,
            EventHotKeyID(signature: 0x53484F54, id: UInt32(id)), GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref = ref { hotkeyRefs[id] = ref; return true }
        return false
    }

    func unregister(_ id: Int) {
        if let ref = hotkeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 570),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "截图助手"
        window.contentMinSize = NSSize(width: 560, height: 550)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "截图，即刻粘贴。")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        root.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "框选或捕捉主屏幕，直接复制到剪贴板。图片不自动保存。")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(subtitle)
        let region = button("框选截图", #selector(regionCapture))
        let full = button("全屏截图 · 主屏幕", #selector(fullCapture))
        region.bezelColor = .controlAccentColor
        let actions = NSStackView(views: [region, full]); actions.spacing = 12
        root.addArrangedSubview(actions)
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 12
        frame.layer?.masksToBounds = true
        frame.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.heightAnchor.constraint(equalToConstant: 202).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(preview); frame.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: frame.topAnchor, constant: 10),
            preview.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: frame.centerYAnchor)
        ])
        root.addArrangedSubview(frame)
        frame.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        copyButton = button("再次复制", #selector(copyRecent))
        saveButton = button("另存为…", #selector(saveRecent))
        copyButton.isEnabled = false; saveButton.isEnabled = false
        let fileActions = NSStackView(views: [copyButton, saveButton]); fileActions.spacing = 10
        root.addArrangedSubview(fileActions)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
        let rule = NSBox(); rule.boxType = .separator
        root.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let settings = NSStackView(); settings.orientation = .horizontal; settings.spacing = 10
        for id in [1, 2] {
            let label = NSTextField(labelWithString: id == 1 ? "框选" : "全屏")
            let control = button(shortcuts[id]!.display + "  修改", #selector(recordShortcut(_:)))
            control.tag = id; shortcutButtons[id] = control
            settings.addArrangedSubview(label); settings.addArrangedSubview(control)
        }
        settings.addArrangedSubview(button("恢复默认", #selector(resetShortcuts)))
        root.addArrangedSubview(settings)
        let hint = NSTextField(labelWithString: "快捷键全局生效 · 框选时按空格切换窗口截图，Esc 取消")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        root.addArrangedSubview(hint)
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.controlSize = .large
        return b
    }

    func makeApplicationMenu() {
        let bar = NSMenu()
        let root = NSMenuItem()
        let menu = NSMenu(title: "截图助手")
        let show = NSMenuItem(title: "打开截图助手", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出截图助手", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        root.submenu = menu
        bar.addItem(root)
        NSApp.mainMenu = bar
    }

    func makeMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "截图助手")
            statusItem.button?.toolTip = "截图助手 · 点击截图或设置快捷键"
        }
        let menu = NSMenu()
        for (title, action) in [("框选截图  \(shortcuts[1]!.display)", #selector(regionCapture)),
                                ("全屏截图  \(shortcuts[2]!.display)", #selector(fullCapture)),
                                ("预览与快捷键设置…", #selector(showWindow))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出截图助手", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    @objc func regionCapture() { capture(1) }
    @objc func fullCapture() { capture(2) }
    @objc func quitApp() { NSApp.terminate(nil) }

    func capture(_ id: Int) {
        guard !capturing, !recording else { NSSound.beep(); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许“截图助手”。授权后如仍不能截图，请退出并重新打开应用。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            showWindow()
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        capturing = true
        let restoreWindow = window.isVisible
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.runCapture(id, restoreWindow: restoreWindow)
        }
    }

    func runCapture(_ id: Int, restoreWindow: Bool) {
        let clipboardCount = NSPasteboard.general.changeCount
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = id == 1 ? ["-i", "-x", "-c", "-t", "png"] : ["-m", "-x", "-c", "-t", "png"]
        let errors = Pipe(); process.standardError = errors
        captureProcess = process
        process.terminationHandler = { [weak self] process in
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            let result = process.terminationStatus
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.capturing = false; self.captureProcess = nil
                let clipboard = NSPasteboard.general
                if result == 0 && clipboard.changeCount != clipboardCount,
                   let image = NSImage(pasteboard: clipboard),
                   let data = clipboard.data(forType: .png) ?? image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
                    self.recentPNG = data; self.recentImage = image
                    self.preview.image = image; self.emptyLabel.isHidden = true
                    self.copyButton.isEnabled = true; self.saveButton.isEnabled = true
                    self.statusLabel.stringValue = "已复制到剪贴板 · 可直接 ⌘V 粘贴 · 未保存文件"
                } else if id == 1 && errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.statusLabel.stringValue = "已取消截图或未取得图片 · 可重新框选"
                } else {
                    self.statusLabel.stringValue = "截图失败，请检查屏幕录制权限后重试。"
                }
                if restoreWindow { self.showWindow() }
            }
        }
        do { try process.run() }
        catch { finishError(error.localizedDescription, restoreWindow) }
    }

    func finishError(_ text: String, _ restore: Bool) {
        capturing = false; captureProcess = nil
        statusLabel.stringValue = "截图失败：\(text)"
        if restore { showWindow() }
    }

    @objc func copyRecent() {
        guard let data = recentPNG else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        let ok = clipboard.setData(data, forType: .png)
        if let tiff = recentImage?.tiffRepresentation { clipboard.setData(tiff, forType: .tiff) }
        statusLabel.stringValue = ok ? "已复制到剪贴板 · 可直接 ⌘V 粘贴 · 未保存文件" : "复制失败，可点击“再次复制”重试。"
    }

    @objc func saveRecent() {
        guard let data = recentPNG else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "截图_\(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); self?.statusLabel.stringValue = "已保存：\(url.lastPathComponent)" }
            catch { self?.statusLabel.stringValue = "保存失败：\(error.localizedDescription)" }
        }
    }

    @objc func recordShortcut(_ sender: NSButton) {
        guard !recording, !capturing else { return }
        recording = true
        unregister(1); unregister(2)
        let id = sender.tag
        let alert = NSAlert()
        alert.messageText = "设置\(id == 1 ? "框选" : "全屏")截图快捷键"
        alert.informativeText = "请直接按下新的组合键，至少包含 ⌘、⌥、⌃ 之一。\n按 Esc 取消；快捷键将自动保存。"
        alert.addButton(withTitle: "取消")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.window.endSheet(alert.window, returnCode: .cancel); return nil }
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { NSSound.beep(); return nil }
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            // Remove modifiers for the label so Option does not display an alternate character.
            let label = special[event.keyCode] ?? self.keyLabel(event)
            let shortcut = Shortcut(code: UInt32(event.keyCode), modifiers: mods, key: label)
            if self.applyShortcut(id, shortcut) {
                self.window.endSheet(alert.window, returnCode: .OK)
            } else {
                alert.informativeText = "该快捷键已被占用或无法注册，原设置已保留。\n请按另一组快捷键，或按 Esc 取消。"
                NSSound.beep()
            }
            return nil
        }
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self = self else { return }
            if let monitor = self.localMonitor { NSEvent.removeMonitor(monitor) }
            self.localMonitor = nil; self.recording = false
            for id in [1, 2] where self.hotkeyRefs[id] == nil {
                if !self.register(id, self.shortcuts[id]!) {
                    self.statusLabel.stringValue = "快捷键无法注册，请重新设置。"
                }
            }
        }
    }

    func keyLabel(_ event: NSEvent) -> String {
        let plain = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.charactersIgnoringModifiers ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: event.keyCode)
        let us: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`"]
        return us[event.keyCode] ?? plain?.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)"
    }

    func applyShortcut(_ id: Int, _ shortcut: Shortcut) -> Bool {
        let other = shortcuts[id == 1 ? 2 : 1]!
        guard other.code != shortcut.code || other.modifiers != shortcut.modifiers else { return false }
        let old = shortcuts[id]!
        unregister(id)
        guard register(id, shortcut) else {
            if !register(id, old) { statusLabel.stringValue = "原快捷键无法恢复，请重新设置。" }
            return false
        }
        shortcuts[id] = shortcut; shortcut.save(id)
        shortcutButtons[id]?.title = shortcut.display + "  修改"
        statusLabel.stringValue = "快捷键已保存，下次启动仍然生效。"
        makeMenu()
        return true
    }

    @objc func resetShortcuts() {
        let old = shortcuts
        unregister(1); unregister(2)
        if register(1, Shortcut.defaults[1]!) && register(2, Shortcut.defaults[2]!) {
            shortcuts = Shortcut.defaults
            for id in [1, 2] { shortcuts[id]!.save(id); shortcutButtons[id]?.title = shortcuts[id]!.display + "  修改" }
            statusLabel.stringValue = "已恢复默认快捷键。"
        } else {
            unregister(1); unregister(2)
            var recovered = true
            for id in [1, 2] { if !register(id, old[id]!) { recovered = false } }
            statusLabel.stringValue = recovered ? "默认快捷键被占用，已保留原设置。" : "部分快捷键无法恢复，请重新设置。"
        }
        makeMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureProcess?.terminate()
        unregister(1); unregister(2)
        if let handler = hotkeyHandler { RemoveEventHandler(handler) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
