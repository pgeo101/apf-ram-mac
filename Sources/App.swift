import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Connect your APF-01 to this Mac by USB, then click Connect.")
    private let cardLabel = NSTextField(labelWithString: "Atari Portfolio · APF-01")
    private let pathLabel = NSTextField(labelWithString: "A:\\")
    private let progress = NSProgressIndicator()
    private var connectButton: NSButton!
    private var openButton: NSButton!
    private var uploadButton: NSButton!
    private var downloadButton: NSButton!
    private var folderButton: NSButton!
    private var backupButton: NSButton!
    private var upButton: NSButton!
    private let session = CardSession()
    private let queue = DispatchQueue(label: "com.local.apfram.card", qos: .userInitiated)
    private var rows: [FATEntry] = []
    private var path = "/"
    private var loaded = false
    private var busy = false
    private var lastBackupURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 890, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "APF RAM for Mac"
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 470)
        window.center()
        let content = NSView(); window.contentView = content
        let title = NSTextField(labelWithString: "APF RAM")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        cardLabel.font = .systemFont(ofSize: 13); cardLabel.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [title, cardLabel]); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 5
        connectButton = button("Connect / Refresh", #selector(connect))
        openButton = button("Open Image…", #selector(openImage))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [identity, spacer, openButton, connectButton]); header.spacing = 12
        upButton = button("↑ Up", #selector(goUp))
        pathLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        let pathBar = NSStackView(views: [upButton, pathLabel]); pathBar.spacing = 12
        pathBar.alignment = .centerY
        let flexible = NSView(); flexible.setContentHuggingPriority(.defaultLow, for: .horizontal); pathBar.addArrangedSubview(flexible)
        for (id, title, width) in [("name", "Name", 410.0), ("kind", "Kind", 130.0), ("size", "Size", 140.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width
            if id == "name" { col.minWidth = 180 }
            table.addTableColumn(col)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        uploadButton = button("Upload…", #selector(upload))
        downloadButton = button("Download…", #selector(download))
        folderButton = button("New Folder…", #selector(newFolder))
        backupButton = button("Back Up Card…", #selector(backup))
        let actionSpace = NSView(); actionSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [uploadButton, downloadButton, folderButton, actionSpace, backupButton]); actions.spacing = 10
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        let help = NSTextField(labelWithString: "Use DOS 8.3 names, such as GAME.COM or TOOLS. Double-click a folder to open it.")
        help.font = .systemFont(ofSize: 11); help.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [header, pathBar, scroll, actions, progress, status, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        for view in [header, pathBar, scroll, actions, progress, status] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        updateButtons()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func buildMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let app = NSMenu(); root.submenu = app
        let about = NSMenuItem(title: "About APF RAM for Mac", action: #selector(aboutApp), keyEquivalent: ""); about.target = self; app.addItem(about)
        app.addItem(.separator())
        let backups = NSMenuItem(title: "Show Automatic Backups", action: #selector(showBackups), keyEquivalent: ""); backups.target = self; app.addItem(backups)
        app.addItem(.separator()); app.addItem(withTitle: "Quit APF RAM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editRoot = NSMenuItem(); menu.addItem(editRoot); let edit = NSMenu(title: "Edit"); editRoot.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    @objc private func aboutApp() {
        let a = NSAlert(); a.messageText = "APF RAM for Mac · 0.2"
        a.informativeText = "Native Apple Silicon utility for APF-01 cards. An independent replacement based on the supplied Windows utility's USB protocol. USB transfers verified on a 512 KB APF-01, hardware v1.2. Other capacities have not been physically tested. Automatic image backups are made before every change."
        a.runModal()
    }
    @objc private func showBackups() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("APF RAM/Backups")
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { let a=NSAlert(); a.messageText="No automatic backups yet"; a.informativeText="The app saves one before each upload or new folder."; a.runModal() }
    }
    private func updateButtons() {
        connectButton.isEnabled = !busy; openButton.isEnabled = !busy
        uploadButton.isEnabled = loaded && !busy; folderButton.isEnabled = loaded && !busy
        backupButton.isEnabled = loaded && !busy
        downloadButton.isEnabled = loaded && !busy && table.selectedRow >= 0
        upButton.isEnabled = loaded && !busy && path != "/"
        table.isEnabled = !busy
    }
    private func fail(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Operation stopped"
        alert.informativeText = error.localizedDescription; alert.runModal()
    }
    private func perform(_ message: String, success: String? = nil, work: @escaping (CardSession.Progress) throws -> Void) {
        guard !busy else { return }
        busy = true; status.stringValue = message; progress.doubleValue = 0; progress.isHidden = false; updateButtons()
        let currentPath = path
        queue.async { [self] in
            let report: CardSession.Progress = { fraction, text in
                DispatchQueue.main.async { [self] in progress.doubleValue = fraction; status.stringValue = text }
            }
            do {
                try work(report)
                let volume = try FAT12Volume(data: session.image)
                let entries = try volume.entries(in: currentPath).sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                let free = try volume.freeBytes
                let label = session.label
                let backupURL = session.lastBackup
                DispatchQueue.main.async { [self] in
                    rows = entries.filter { $0.name != "." && $0.name != ".." }; loaded = true; busy = false
                    lastBackupURL = backupURL
                    cardLabel.stringValue = label
                    pathLabel.stringValue = "A:" + currentPath.replacingOccurrences(of: "/", with: "\\")
                    status.stringValue = (success.map { $0 + " · " } ?? "") + "\(rows.count) items · \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free"
                    progress.isHidden = true; table.reloadData(); updateButtons()
                }
            } catch {
                let usable = !session.image.isEmpty && !session.needsReconnect
                var recoveryPath = currentPath
                var recoveryRows: [FATEntry] = []
                if usable, let volume = try? FAT12Volume(data: session.image) {
                    if let entries = try? volume.entries(in: recoveryPath) { recoveryRows = entries }
                    else { recoveryPath = "/"; recoveryRows = (try? volume.entries(in: "/")) ?? [] }
                }
                let restoredPath = recoveryPath, restoredRows = recoveryRows
                DispatchQueue.main.async { [self] in
                    busy = false; loaded = usable; progress.isHidden = true
                    path = restoredPath; rows = usable ? restoredRows : []
                    pathLabel.stringValue = "A:" + path.replacingOccurrences(of: "/", with: "\\")
                    table.reloadData()
                    status.stringValue = error.localizedDescription; updateButtons(); fail(error)
                }
            }
        }
    }
    @objc private func connect() {
        path = "/"; loaded = false
        perform("Detecting APF-01…", success: "Card loaded") { [self] report in try session.connect(progress: report) }
    }
    @objc private func openImage() {
        let panel = NSOpenPanel(); panel.title = "Open a Portfolio FAT12 card image"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = "/"
        perform("Opening image…") { [self] _ in try session.openImage(url) }
    }
    private func childPath(_ name: String) -> String { path == "/" ? "/"+name : path+"/"+name }
    @objc private func goUp() {
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        perform("Opening folder…") { _ in }
    }
    @objc private func openSelected() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, rows[row].isDirectory else { return }
        path = childPath(rows[row].name); perform("Opening folder…") { _ in }
    }
    @objc private func upload() {
        let panel=NSOpenPanel(); panel.title="Upload files or folders to A:"; panel.canChooseDirectories=true; panel.allowsMultipleSelection=true
        guard panel.runModal() == .OK else { return }
        let urls=panel.urls, directory=path
        perform("Preparing upload…", success: "Upload verified") { [self] report in
            var volume=try FAT12Volume(data:session.image)
            func add(_ url: URL, at destination: String, depth: Int) throws {
                guard depth<64 else { throw APFError("Folder nesting is too deep") }
                let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey])
                guard values.isSymbolicLink != true else { throw APFError("Symbolic links cannot be uploaded: \(url.lastPathComponent)") }
                if values.isDirectory == true {
                    try volume.createDirectory(name:url.lastPathComponent,in:destination)
                    let next=destination == "/" ? "/"+url.lastPathComponent : destination+"/"+url.lastPathComponent
                    for child in try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]).sorted(by:{$0.lastPathComponent < $1.lastPathComponent}) {
                        try add(child,at:next,depth:depth+1)
                    }
                } else if values.isRegularFile == true {
                    let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size<=session.image.count else { throw APFError("\(url.lastPathComponent) is larger than this card") }
                    try volume.putFile(name:url.lastPathComponent,contents:Data(contentsOf:url),in:destination,overwrite:false)
                } else { throw APFError("Unsupported file: \(url.lastPathComponent)") }
            }
            for url in urls { try add(url,at:directory,depth:0) }
            try session.commit(volume.data,progress:report)
        }
    }
    @objc private func download() {
        let selected=table.selectedRow
        guard selected>=0, selected<rows.count else { return }
        let entry=rows[selected], source=childPath(rows[selected].name)
        let panel=NSSavePanel(); panel.title="Download from APF-01"; panel.nameFieldStringValue=entry.name
        guard panel.runModal() == .OK, let destination=panel.url else { return }
        if entry.isDirectory && FileManager.default.fileExists(atPath:destination.path) {
            fail(APFError("Choose a new folder name for this download")); return
        }
        perform("Downloading…", success: "Download saved") { [self] _ in
            let volume=try FAT12Volume(data:session.image)
            func save(_ source: String, to target: URL, directory: Bool, depth: Int) throws {
                guard depth<128 else { throw APFError("Directory nesting is too deep") }
                if directory {
                    try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
                    for child in try volume.entries(in:source) where child.name != "." && child.name != ".." {
                        // FAT parser validates each short filename. Also enforce
                        // a single path component at this filesystem boundary.
                        guard !child.name.contains("/"), !child.name.contains("\\") else { throw APFError("Invalid card filename") }
                        try save(source+"/"+child.name,to:target.appendingPathComponent(child.name),directory:child.isDirectory,depth:depth+1)
                    }
                } else { try volume.readFile(path:source).write(to:target,options:.atomic) }
            }
            try save(source,to:destination,directory:entry.isDirectory,depth:0)
        }
    }
    @objc private func newFolder() {
        let alert=NSAlert(); alert.messageText="New folder on A:"; alert.informativeText="Enter a DOS name of up to 8 characters."
        let field=NSTextField(frame:NSRect(x:0,y:0,width:260,height:24)); alert.accessoryView=field
        alert.addButton(withTitle:"Create"); alert.addButton(withTitle:"Cancel")
        alert.window.initialFirstResponder=field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name=field.stringValue, directory=path
        perform("Creating folder…",success:"Folder created and verified") { [self] report in
            var volume=try FAT12Volume(data:session.image)
            try volume.createDirectory(name:name,in:directory)
            try session.commit(volume.data,progress:report)
        }
    }
    @objc private func backup() {
        let panel=NSSavePanel(); panel.title="Save complete card image"; panel.nameFieldStringValue="Portfolio.img"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        perform("Saving backup…",success:"Backup saved") { [self] _ in try session.image.write(to:url,options:.atomic) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy {
            let a=NSAlert(); a.messageText="A card operation is running"; a.informativeText="Wait for it to finish before quitting."; a.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { NSSound.beep(); return false }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry=rows[row], id=tableColumn?.identifier.rawValue ?? "name"
        let text: String
        switch id { case "kind": text=entry.isDirectory ? "Folder" : "File"
        case "size": text=entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount:Int64(entry.size),countStyle:.file)
        default: text=(entry.isDirectory ? "▸  " : "    ")+entry.name }
        let cell=NSTextField(labelWithString:text); cell.font = id == "name" ? .monospacedSystemFont(ofSize:13,weight:.regular) : .systemFont(ofSize:12)
        cell.lineBreakMode = .byTruncatingTail; return cell
    }
}

@main struct APFRAM {
    static func main() {
        if CommandLine.arguments.count>1 {
            do {
                switch CommandLine.arguments[1] {
                case "--help":
                    print("APF RAM for Mac\n  --probe           Read identity and boot sector only\n  --list            Read card and list root directory\n  --backup PATH     Read card and save complete image\n  --inspect PATH    List the root of a saved FAT12 image\nNo CLI command writes to a connected card.")
                case "--probe":
                    let card=try APFConnection(), boot=try card.readSector(0,bytesPerSector:0)
                    guard try card.readSector(0,bytesPerSector:boot.count)==boot else { throw APFError("Repeated boot reads differ") }
                    print("\(card.label)\nSector size: \(boot.count) bytes. Repeated boot read matches. No card writes.")
                case "--list", "--backup", "--inspect":
                    let command=CommandLine.arguments[1], session=CardSession()
                    if command=="--inspect" {
                        guard CommandLine.arguments.count==3 else { throw APFError("Expected an image path") }
                        try session.openImage(URL(fileURLWithPath:CommandLine.arguments[2]))
                    } else {
                        if command=="--backup" && CommandLine.arguments.count != 3 { throw APFError("Expected a destination path") }
                        var lastBucket = -1
                        try session.connect { fraction, message in
                            let bucket = Int(fraction * 10)
                            if bucket != lastBucket { fputs(message+"\n",stderr); lastBucket = bucket }
                        }
                    }
                    let volume=try FAT12Volume(data:session.image)
                    print(session.label)
                    for entry in try volume.entries(in:"/") { print("\(entry.isDirectory ? "<DIR>" : String(entry.size))\t\(entry.name)") }
                    print("\(try volume.freeBytes) bytes free")
                    if command=="--backup" { try session.image.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.withoutOverwriting); print("Backup saved. No card writes.") }
                default: throw APFError("Unknown option. Use --help")
                }
            } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
            return
        }
        let app=NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate=AppDelegate(); app.delegate=delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
