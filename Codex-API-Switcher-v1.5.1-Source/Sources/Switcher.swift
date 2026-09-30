import Cocoa
import Security

private enum Theme {
    static let background = NSColor.black
    static let surface = NSColor(calibratedWhite: 0.075, alpha: 1)
    static let surfaceRaised = NSColor(calibratedWhite: 0.11, alpha: 1)
    static let separator = NSColor(calibratedWhite: 0.22, alpha: 1)
    static let green = NSColor(calibratedRed: 0.22, green: 0.84, blue: 0.43, alpha: 1)
    static let greenPressed = NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.34, alpha: 1)
}

private final class CardView: NSView {
    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.separator.withAlphaComponent(0.65).cgColor
    }
    required init?(coder: NSCoder) { nil }
}

private final class GreenButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = Theme.green.cgColor
        layer?.cornerRadius = 12
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = Theme.greenPressed.cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = Theme.green.cgColor
    }
}

private final class APITokenField: NSSecureTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("api-token-input")
        contentType = nil
        isAutomaticTextCompletionEnabled = false
    }
    required init?(coder: NSCoder) { nil }
}

struct APIKeyEntry: Codable, Equatable {
    let id: UUID
    var name: String
    let service: String
}

enum AppProfile {
    case switcher
    case subscription
    case api

    static var current: AppProfile {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.hasSuffix(".subscription") {
            return .subscription
        } else if bundleID.hasSuffix(".api") {
            return .api
        }
        return .switcher
    }

    var appName: String {
        switch self {
        case .switcher: return "Codex API Switcher"
        case .subscription: return "ChatGPT Subscription"
        case .api: return "ChatGPT API"
        }
    }

    var defaultProvider: String {
        switch self {
        case .switcher: return "openai"
        case .subscription: return "openai"
        case .api: return "model_api"
        }
    }
}

final class KeyStore {
    private let managedStart = "# BEGIN CODEX API SWITCHER MANAGED PROVIDERS"
    private let managedEnd = "# END CODEX API SWITCHER MANAGED PROVIDERS"
    let fm = FileManager.default
    let home = FileManager.default.homeDirectoryForCurrentUser
    lazy var codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    let profile = AppProfile.current

    lazy var ttmRegistryURL = codexDir.appendingPathComponent("ttm-api-keys.json")
    lazy var openaiRegistryURL = codexDir.appendingPathComponent("openai-api-keys.json")
    lazy var unifiedRegistryURL = codexDir.appendingPathComponent("api-keys.json")

    lazy var activeServiceURL = codexDir.appendingPathComponent("active-service")
    lazy var ttmActiveURL = codexDir.appendingPathComponent("ttm-active-service")
    lazy var openaiActiveURL = codexDir.appendingPathComponent("openai-active-service")

    lazy var configURL = codexDir.appendingPathComponent("config.toml")
    lazy var helperURL = codexDir.appendingPathComponent("ttm-active-token.sh")
    var entries: [APIKeyEntry] = []
    var setupError: Error?

    init() {
        do {
            try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try installTokenHelper()
            try ensureAllProviders()
        } catch {
            setupError = error
        }
        load()
        migrateLegacyKeyIfNeeded()
    }

    var account: String { NSUserName() }

    private func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    func installTokenHelper() throws {
        let script = """
        #!/bin/zsh
        set -eu
        codex_dir=\(codexDir.path.replacingOccurrences(of: "'", with: "'\\''").debugDescription)
        keychain_account=\(account.replacingOccurrences(of: "'", with: "'\\''").debugDescription)
        active_service=""
        for f in "$codex_dir/active-service" "$codex_dir/ttm-active-service" "$codex_dir/openai-active-service"; do
          if [[ -s "$f" ]]; then
            line="$(head -n 1 "$f" | tr -d '\\r\\n')"
            if [[ -n "$line" ]]; then
              active_service="$line"
              break
            fi
          fi
        done
        if [[ -z "$active_service" ]]; then
          print -u2 "No active API key is selected."
          exit 1
        fi
        exec /usr/bin/security find-generic-password -a "$keychain_account" -s "$active_service" -w
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
    }

    func ensureAllProviders() throws {
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if let start = text.range(of: managedStart),
           let end = text.range(of: managedEnd, range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = removingLegacyProviderTables(from: text)

        let helper = tomlString(helperURL.path)
        let block = """
        \(managedStart)
        [model_providers.model_api]
        name = "Model API"
        base_url = "https://modelapi.vn/v1"
        wire_api = "responses"
        supports_websockets = false

        [model_providers.model_api.auth]
        command = "\(helper)"
        timeout_ms = 15000
        refresh_interval_ms = 0

        [model_providers.aioffer]
        name = "AIOffer API"
        base_url = "https://api.aioffer.tech/v1"
        wire_api = "responses"
        supports_websockets = false

        [model_providers.aioffer.auth]
        command = "\(helper)"
        timeout_ms = 15000
        refresh_interval_ms = 0

        [model_providers.aioffer.http_headers]
        x-openai-actor-authorization = "cockpit-tools"
        x-agtools-disable-image-generation = "chat"
        x-cockpit-instance-id = ".codex"

        [model_providers.ttm]
        name = "TTM API"
        base_url = "https://ttmapi.site/v1"
        wire_api = "responses"
        supports_websockets = false

        [model_providers.ttm.auth]
        command = "\(helper)"
        timeout_ms = 15000
        refresh_interval_ms = 0

        [model_providers.ttm.http_headers]
        x-openai-actor-authorization = "cockpit-tools"
        x-agtools-disable-image-generation = "chat"
        x-cockpit-instance-id = ".codex"

        [model_providers.openai_api]
        name = "OpenAI API"
        base_url = "https://api.openai.com/v1"
        wire_api = "responses"
        supports_websockets = false

        [model_providers.openai_api.auth]
        command = "\(helper)"
        timeout_ms = 15000
        refresh_interval_ms = 0
        \(managedEnd)
        """

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { text += "\n\n" }
        text += block + "\n"
        try writeConfig(text)
    }

    private func removingLegacyProviderTables(from text: String) -> String {
        let managedIDs = ["model_api", "aioffer", "ttm", "openai_api"]
        var output: [String] = []
        var skipping = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let isManagedTable = managedIDs.contains { id in
                    trimmed == "[model_providers.\(id)]" ||
                    trimmed.hasPrefix("[model_providers.\(id).")
                }
                skipping = isManagedTable
            }
            if !skipping { output.append(line) }
        }
        return output.joined(separator: "\n")
    }

    private func writeConfig(_ text: String) throws {
        let backupURL = codexDir.appendingPathComponent("config.toml.switcher-backup")
        if fm.fileExists(atPath: configURL.path), !fm.fileExists(atPath: backupURL.path) {
            let current = try Data(contentsOf: configURL)
            try current.write(to: backupURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func load() {
        var loaded: [APIKeyEntry] = []

        let candidateURLs = [unifiedRegistryURL, ttmRegistryURL, openaiRegistryURL]
        for url in candidateURLs {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([APIKeyEntry].self, from: data) {
                for item in decoded {
                    if !loaded.contains(where: { $0.id == item.id || $0.service == item.service }) {
                        loaded.append(item)
                    }
                }
            }
        }
        entries = loaded
    }

    func saveRegistry() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        for url in [unifiedRegistryURL, ttmRegistryURL, openaiRegistryURL] {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func migrateLegacyKeyIfNeeded() {
        let legacyService = "codex-ttm-api-key"
        if entries.isEmpty, keyExists(service: legacyService) {
            entries = [APIKeyEntry(id: UUID(), name: "TTM API 1", service: legacyService)]
            saveRegistry()
            if activeService == nil { setActive(legacyService) }
        }
    }

    var activeService: String? {
        for url in [activeServiceURL, ttmActiveURL, openaiActiveURL] {
            if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func setActive(_ service: String) {
        let content = service + "\n"
        for url in [activeServiceURL, ttmActiveURL, openaiActiveURL] {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func keyExists(service: String) -> Bool {
        var item: SecKeychainItem?
        let status = SecKeychainFindGenericPassword(nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            nil, nil, &item)
        return status == errSecSuccess
    }

    func saveKey(service: String, password: String) -> OSStatus {
        var item: SecKeychainItem?
        var length: UInt32 = 0
        var data: UnsafeMutableRawPointer?
        let findStatus = SecKeychainFindGenericPassword(nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            &length, &data, &item)
        if let data { SecKeychainItemFreeContent(nil, data) }

        return password.withCString { passwordPtr in
            if findStatus == errSecSuccess, let item {
                return SecKeychainItemModifyAttributesAndData(item, nil,
                    UInt32(password.utf8.count), passwordPtr)
            }
            return SecKeychainAddGenericPassword(nil,
                UInt32(service.utf8.count), service,
                UInt32(account.utf8.count), account,
                UInt32(password.utf8.count), passwordPtr, nil)
        }
    }

    func deleteKey(_ entry: APIKeyEntry) {
        var item: SecKeychainItem?
        let status = SecKeychainFindGenericPassword(nil,
            UInt32(entry.service.utf8.count), entry.service,
            UInt32(account.utf8.count), account,
            nil, nil, &item)
        if status == errSecSuccess, let item { SecKeychainItemDelete(item) }
        entries.removeAll { $0.id == entry.id }
        saveRegistry()
        if activeService == entry.service, let first = entries.first {
            setActive(first.service)
        }
    }

    func provider() -> String {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return profile.defaultProvider }
        let pattern = #"(?m)^\s*model_provider\s*=\s*\"([^\"]+)\"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return profile.defaultProvider }
        return String(text[range])
    }

    func setProvider(_ provider: String) throws {
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let pattern = #"(?m)^\s*model_provider\s*=.*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            text = regex.stringByReplacingMatches(in: text, range: range,
                withTemplate: "model_provider = \"\(provider)\"")
        } else {
            text = "model_provider = \"\(provider)\"\n" + text
        }
        try writeConfig(text)
    }

    func currentModel() -> String {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return "gpt-5.6-sol" }
        let pattern = #"(?m)^\s*model\s*=\s*\"([^\"]+)\"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return "gpt-5.6-sol" }
        return String(text[range])
    }

    func setModel(_ model: String) throws {
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let pattern = #"(?m)^\s*model\s*=.*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            text = regex.stringByReplacingMatches(in: text, range: range,
                withTemplate: "model = \"\(model)\"")
        } else {
            text = "model = \"\(model)\"\n" + text
        }
        try writeConfig(text)
    }
}

final class ViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let store = KeyStore()

    let openAICheckbox = NSButton(checkboxWithTitle: "OpenAI / ChatGPT (Subscription)", target: nil, action: nil)
    let modelAPICheckbox = NSButton(checkboxWithTitle: "Model API", target: nil, action: nil)
    let aiofferCheckbox = NSButton(checkboxWithTitle: "AIOffer API", target: nil, action: nil)
    let ttmCheckbox = NSButton(checkboxWithTitle: "TTM API", target: nil, action: nil)
    let openAIAPICheckbox = NSButton(checkboxWithTitle: "OpenAI API", target: nil, action: nil)

    let modelComboBox = NSComboBox()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    let activeLabel = NSTextField(labelWithString: "")
    let taskNotice = NSTextField(wrappingLabelWithString: "⚠️ Provider và API key mới chỉ áp dụng cho TASK MỚI. Task/Goal cũ vẫn giữ provider ban đầu và có thể báo Goal Usage Limit sai nguồn.")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 740))
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor
        buildUI()
        refresh()
    }

    func buildUI() {
        let title = NSTextField(labelWithString: store.profile.appName)
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .white

        let subtitle = NSTextField(wrappingLabelWithString: "Quản lý và chuyển đổi nhanh giữa các Provider Codex (ChatGPT Subscription, Model API, AIOffer API, TTM API, OpenAI API).")
        subtitle.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8

        // Provider checkboxes setup
        openAICheckbox.target = self
        openAICheckbox.action = #selector(providerCheckboxChanged(_:))
        modelAPICheckbox.target = self
        modelAPICheckbox.action = #selector(providerCheckboxChanged(_:))
        aiofferCheckbox.target = self
        aiofferCheckbox.action = #selector(providerCheckboxChanged(_:))
        ttmCheckbox.target = self
        ttmCheckbox.action = #selector(providerCheckboxChanged(_:))
        openAIAPICheckbox.target = self
        openAIAPICheckbox.action = #selector(providerCheckboxChanged(_:))

        let providerChecksRow1 = NSStackView(views: [openAICheckbox, modelAPICheckbox, aiofferCheckbox])
        providerChecksRow1.orientation = .horizontal
        providerChecksRow1.spacing = 24

        let providerChecksRow2 = NSStackView(views: [ttmCheckbox, openAIAPICheckbox])
        providerChecksRow2.orientation = .horizontal
        providerChecksRow2.spacing = 24

        let providerTitle = NSTextField(labelWithString: "PROVIDER")
        providerTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        providerTitle.textColor = .tertiaryLabelColor

        // Model field setup
        let modelLabel = NSTextField(labelWithString: "Codex Model:")
        modelLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        modelLabel.textColor = .secondaryLabelColor

        modelComboBox.isEditable = true
        modelComboBox.addItems(withObjectValues: [
            "gpt-5.6-sol",
            "gpt-6-astra",
            "gpt-5.6-luna",
            "gpt-5-codex",
            "gpt-4o"
        ])
        modelComboBox.stringValue = store.currentModel()
        modelComboBox.translatesAutoresizingMaskIntoConstraints = false
        modelComboBox.heightAnchor.constraint(equalToConstant: 26).isActive = true
        modelComboBox.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let modelHint = NSTextField(labelWithString: "(Gợi ý: gpt-6-astra cho AIOffer, gpt-5.6-sol cho Model API / OpenAI, gpt-5.6-luna cho TTM)")
        modelHint.font = .systemFont(ofSize: 11)
        modelHint.textColor = .tertiaryLabelColor

        let modelRow = NSStackView(views: [modelLabel, modelComboBox, modelHint])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 10

        let providerStack = NSStackView(views: [providerTitle, providerChecksRow1, providerChecksRow2, modelRow])
        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 12
        providerStack.translatesAutoresizingMaskIntoConstraints = false

        let providerCard = CardView()
        providerCard.addSubview(providerStack)
        NSLayoutConstraint.activate([
            providerStack.leadingAnchor.constraint(equalTo: providerCard.leadingAnchor, constant: 20),
            providerStack.trailingAnchor.constraint(lessThanOrEqualTo: providerCard.trailingAnchor, constant: -20),
            providerStack.topAnchor.constraint(equalTo: providerCard.topAnchor, constant: 16),
            providerStack.bottomAnchor.constraint(equalTo: providerCard.bottomAnchor, constant: -16)
        ])

        // Table setup
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Tên API key"
        nameColumn.width = 540

        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "Trạng thái"
        stateColumn.width = 180

        table.addTableColumn(nameColumn)
        table.addTableColumn(stateColumn)
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 40
        table.backgroundColor = Theme.surfaceRaised
        table.gridColor = Theme.separator
        table.intercellSpacing = NSSize(width: 8, height: 4)
        table.allowsEmptySelection = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surfaceRaised
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let add = GreenButton(title: "+ Thêm API key…", target: self, action: #selector(addKey))
        let remove = GreenButton(title: "− Xóa", target: self, action: #selector(removeKey))
        let save = GreenButton(title: "Save • Reset & Task mới", target: self, action: #selector(saveAndReset))
        save.keyEquivalent = "\r"

        add.widthAnchor.constraint(greaterThanOrEqualToConstant: 144).isActive = true
        remove.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        save.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let buttons = NSStackView(views: [add, remove, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        activeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        taskNotice.textColor = .systemOrange
        taskNotice.font = .systemFont(ofSize: 13, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2

        let keysTitle = NSTextField(labelWithString: "API KEYS TRONG KEYCHAIN (DÙNG CHO MODEL API / AIOFFER / TTM / OPENAI API)")
        keysTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        keysTitle.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            heading,
            providerCard,
            taskNotice,
            activeLabel,
            keysTitle,
            scroll,
            buttons,
            status
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -32),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            providerCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            taskNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keysTitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func refresh(message: String? = nil) {
        let provider = store.provider()
        openAICheckbox.state = provider == "openai" ? .on : .off
        modelAPICheckbox.state = provider == "model_api" ? .on : .off
        aiofferCheckbox.state = provider == "aioffer" ? .on : .off
        ttmCheckbox.state = provider == "ttm" ? .on : .off
        openAIAPICheckbox.state = provider == "openai_api" ? .on : .off

        let active = store.entries.first { $0.service == store.activeService }
        activeLabel.stringValue = "Key đang kích hoạt: \(active?.name ?? "Chưa chọn (hoặc đang dùng ChatGPT Subscription)")"

        table.reloadData()
        if let active, let row = store.entries.firstIndex(of: active) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let message {
            status.stringValue = message
        } else if let error = store.setupError {
            status.textColor = .systemRed
            status.stringValue = "Không thể chuẩn bị cấu hình Codex: \(error.localizedDescription)"
        }
    }

    @objc func providerCheckboxChanged(_ sender: NSButton) {
        openAICheckbox.state = sender === openAICheckbox ? .on : .off
        modelAPICheckbox.state = sender === modelAPICheckbox ? .on : .off
        aiofferCheckbox.state = sender === aiofferCheckbox ? .on : .off
        ttmCheckbox.state = sender === ttmCheckbox ? .on : .off
        openAIAPICheckbox.state = sender === openAIAPICheckbox ? .on : .off

        // Auto-suggest model based on provider
        if aiofferCheckbox.state == .on {
            modelComboBox.stringValue = "gpt-6-astra"
        } else if ttmCheckbox.state == .on {
            modelComboBox.stringValue = "gpt-5.6-luna"
        } else if modelAPICheckbox.state == .on {
            modelComboBox.stringValue = "gpt-5.6-sol"
        } else if openAICheckbox.state == .on || openAIAPICheckbox.state == .on {
            modelComboBox.stringValue = "gpt-5.6-sol"
        }

        status.stringValue = "Đã chọn \(sender.title). Bấm 'Save • Reset & Task mới' để áp dụng."
    }

    @objc func addKey() {
        let alert = NSAlert()
        alert.messageText = "Thêm API Key mới"
        alert.informativeText = "API key sẽ được lưu an toàn trong macOS Keychain của tài khoản hiện tại."
        alert.addButton(withTitle: "Thêm")
        alert.addButton(withTitle: "Hủy")
        styleAlert(alert)

        let name = NSTextField(string: "API Key \(store.entries.count + 1)")
        name.placeholderString = "Tên gợi nhớ (VD: AIOffer 1, Model API, TTM Key...)"
        name.isAutomaticTextCompletionEnabled = false
        let password = APITokenField(frame: .zero)
        password.placeholderString = "Dán API key tại đây"
        name.translatesAutoresizingMaskIntoConstraints = false
        password.translatesAutoresizingMaskIntoConstraints = false
        name.heightAnchor.constraint(equalToConstant: 32).isActive = true
        password.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let nameLabel = NSTextField(labelWithString: "Tên gợi nhớ:")
        let keyLabel = NSTextField(labelWithString: "API key:")
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let form = NSStackView(views: [nameLabel, name, keyLabel, password])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 144))
        accessory.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            form.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 8),
            name.widthAnchor.constraint(equalTo: form.widthAnchor),
            password.widthAnchor.constraint(equalTo: form.widthAnchor)
        ])
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cleanName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = password.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !key.isEmpty else { showError("Tên gợi nhớ và API key không được để trống."); return }

        let entry = APIKeyEntry(id: UUID(), name: cleanName, service: "codex-api-key-\(UUID().uuidString)")
        let result = store.saveKey(service: entry.service, password: key)
        guard result == errSecSuccess else { showError("Không thể lưu vào Keychain (mã lỗi \(result))."); return }
        store.entries.append(entry)
        store.saveRegistry()
        table.reloadData()
        if let row = store.entries.firstIndex(of: entry) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            store.setActive(entry.service)
        }
        status.stringValue = "Đã thêm \(cleanName). Chọn Provider mong muốn rồi bấm Save để kích hoạt."
    }

    @objc func saveAndReset() {
        let provider = selectedProvider()
        var displayName = providerDisplayName(provider)

        // Providers requiring API keys from Keychain
        if provider != "openai" {
            guard !store.entries.isEmpty else {
                showError("Vui lòng bấm '+ Thêm API key…' để nhập API key cho \(displayName).")
                return
            }
            let row = table.selectedRow
            guard row >= 0, row < store.entries.count else {
                showError("Hãy chọn API key trong danh sách để sử dụng với \(displayName).")
                return
            }
            let entry = store.entries[row]
            guard store.keyExists(service: entry.service) else {
                showError("API key ‘\(entry.name)’ không còn trong Keychain. Hãy xóa mục này và thêm lại key.")
                return
            }
            store.setActive(entry.service)
            displayName += " – [Key: \(entry.name)]"
        }

        let modelChoice = modelComboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelToSet = modelChoice.isEmpty ? defaultModelForProvider(provider) : modelChoice

        do {
            try store.installTokenHelper()
            try store.ensureAllProviders()
            try store.setModel(modelToSet)
            try store.setProvider(provider)
            refresh(message: "Đã kích hoạt \(displayName) với Model \(modelToSet). Mở Codex và tạo TASK MỚI.")
            showNewTaskNotice(providerName: "\(displayName) (Model: \(modelToSet))")
        } catch {
            showError("Không thể cập nhật config.toml: \(error.localizedDescription)")
        }
    }

    func selectedProvider() -> String {
        if modelAPICheckbox.state == .on { return "model_api" }
        if aiofferCheckbox.state == .on { return "aioffer" }
        if ttmCheckbox.state == .on { return "ttm" }
        if openAIAPICheckbox.state == .on { return "openai_api" }
        return "openai"
    }

    func defaultModelForProvider(_ provider: String) -> String {
        switch provider {
        case "aioffer": return "gpt-6-astra"
        case "ttm": return "gpt-5.6-luna"
        case "model_api": return "gpt-5.6-sol"
        case "openai_api": return "gpt-5.6-sol"
        default: return "gpt-5.6-sol"
        }
    }

    func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "model_api": return "Model API"
        case "aioffer": return "AIOffer API"
        case "ttm": return "TTM API"
        case "openai_api": return "OpenAI API"
        default: return "OpenAI / ChatGPT Subscription"
        }
    }

    @objc func removeKey() {
        let row = table.selectedRow
        guard row >= 0, row < store.entries.count else { showError("Hãy chọn API key cần xóa trong bảng."); return }
        let entry = store.entries[row]
        let alert = NSAlert()
        alert.messageText = "Xóa \(entry.name)?"
        alert.informativeText = "API key sẽ bị xóa vĩnh viễn khỏi macOS Keychain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Xóa")
        alert.addButton(withTitle: "Hủy")
        styleAlert(alert)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteKey(entry)
        refresh(message: "Đã xóa \(entry.name).")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = store.entries[row]
        let isStateCol = tableColumn?.identifier.rawValue == "state"
        let labelText: String
        if isStateCol {
            labelText = (entry.service == store.activeService) ? "✓ Đang kích hoạt" : ""
        } else {
            labelText = entry.name
        }
        let text = NSTextField(labelWithString: labelText)
        if isStateCol && entry.service == store.activeService {
            text.textColor = Theme.green
            text.font = .systemFont(ofSize: 13, weight: .bold)
        }
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Codex API Switcher"
        alert.informativeText = message
        alert.alertStyle = .warning
        styleAlert(alert)
        alert.runModal()
    }

    func styleAlert(_ alert: NSAlert) {
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.window.backgroundColor = Theme.surface
        alert.buttons.forEach {
            $0.bezelColor = Theme.green
            $0.contentTintColor = .black
        }
    }

    func showNewTaskNotice(providerName: String) {
        let alert = NSAlert()
        alert.messageText = "Đã Save & Reset sang \(providerName)"
        alert.informativeText = "Cấu hình Codex đã sẵn sàng. Hãy mở Codex và bấm New Task để bắt đầu với Provider mới. Task/Goal cũ vẫn giữ nguyên provider ban đầu."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Mở Codex")
        alert.addButton(withTitle: "Đóng")
        styleAlert(alert)
        if alert.runModal() == .alertFirstButtonReturn,
           let codexURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: codexURL, configuration: configuration)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        let controller = ViewController()
        window = NSWindow(contentViewController: controller)
        window.title = AppProfile.current.appName
        window.setContentSize(NSSize(width: 840, height: 740))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 800, height: 700)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
