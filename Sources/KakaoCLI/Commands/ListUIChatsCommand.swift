import ArgumentParser
import Foundation
import KakaoCore

struct ListUIChatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-ui-chats",
        abstract: "List KakaoTalk chat-list UI display names (_NS:40), read-only (for debugging send matching)"
    )
    @Option(name: .long, help: "Dump first N rows recursively instead of listing names")
    var dumpFirst: Int = 0
    @Option(name: .long, help: "Test search-filter with this query, then list names")
    var search: String?
    func run() throws {
        let bundleId = "com.kakao.KakaoTalkMac"
        try AXHelpers.activateApp(bundleId: bundleId)
        let app = try AXHelpers.appElement(bundleId: bundleId)
        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            print("Could not find main window"); throw ExitCode.failure
        }
        if let q = search {
            // SPEED: reuse the _NS:20 fast path (direct-child check) like
            // the send path, instead of a depth-4 DFS over the whole window.
            var fieldOpt = AXHelpers.findSearchField(mainWindow)
                ?? AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
            if fieldOpt == nil, let btn = AXHelpers.findFirstByDescription(mainWindow, desc: "검색", maxDepth: 3) {
                _ = AXHelpers.performAction(btn, "AXPress")
                _ = AXHelpers.poll(timeout: 1.5) {
                    fieldOpt = AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
                    return fieldOpt != nil
                }
                print("search button pressed")
            }
            if let field = fieldOpt {
                print("search field found role=\(AXHelpers.role(field) ?? "?") id=\(AXHelpers.identifier(field) ?? "?")")
                // SPEED: skip focus/re-type when the field already holds q.
                if AXHelpers.value(field) != q {
                    _ = AXHelpers.focus(field)
                    if !AXHelpers.setValue(field, q) { AXHelpers.clickElement(field); AXHelpers.typeText(q) }
                } else { print("search field already holds query; not re-typing") }
                if let tbl = AXHelpers.chatListTable(mainWindow) {
                    _ = AXHelpers.poll(timeout: 1.2) { AXHelpers.children(tbl).count < 200 }
                }
            } else { print("search field NOT found") }
        }
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            print("Could not find chat list table"); throw ExitCode.failure
        }
        if dumpFirst > 0 {
            for (i, row) in AXHelpers.children(table).prefix(dumpFirst).enumerated() {
                print("=== ROW \(i) ===")
                print(AXHelpers.dumpTree(row, maxDepth: 8))
            }
            return
        }
        let names = AXHelpers.chatRowNames(table)
        for (i, n) in names.enumerated() { print("\(i)\t\(n)") }
        fputs("[kakaocli] list-ui-chats: \(names.count) rows\n", stderr)
    }
}
