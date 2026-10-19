import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        let sendStart = Date()
        func stage(_ name: String) {
            fputs("[kakaocli] stage=\(name) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(sendStart)))s\n", stderr)
        }
        // 1. Ensure KakaoTalk is running and logged in.
        // NOTE: do NOT call detectState() here as well as inside
        // ensureReady() — that duplicated a full state detection
        // (previously ~46s each) on every send.
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        stage("ensureReady")

        // 2. Activate KakaoTalk and get windows
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 3. Close any existing chat windows to avoid sending to the wrong one
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. Ensure we're on the Chats tab.
        // If the chat-list table is already present we ARE on the Chats tab:
        // skip the tab search entirely. Searching for the "chatrooms"
        // checkbox with findFirst walks the AX tree and, even bounded to
        // depth 5, descends into the 500+ row table — that cost 41.1s in
        // the 2026-10-19 stage timings (activate+window+tab stage).
        // Only search for (and press) the tab when no table is present,
        // in which case the tree being searched has no table to walk.
        if AXHelpers.chatListTable(mainWindow) == nil {
            if let chatroomsTab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms", maxDepth: 5) {
                _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        // 4b. Fast path: use the Chats-tab search to filter the list first,
        // so findChatRow scans a handful of rows instead of 500+.
        // Query = first name token; correctness does NOT rely on the query:
        // findChatRow still requires substring / all-token unique match.
        var searchField: AXUIElement? = nil
        if !selfChat {
            var existingField = AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
            if existingField == nil, let btn = AXHelpers.findFirstByDescription(mainWindow, desc: "검색", maxDepth: 3) {
                _ = AXHelpers.performAction(btn, kAXPressAction as String)
                _ = AXHelpers.poll(timeout: 1.5) {
                    existingField = AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
                    return existingField != nil
                }
            }
            if let field = existingField {
                searchField = field
                let query = chatName.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? chatName
                _ = AXHelpers.focus(field)
                if !AXHelpers.setValue(field, String(query)) {
                    AXHelpers.clickElement(field)
                    AXHelpers.typeText(String(query))
                }
                // Poll cheaply (one AX call for row count) until the list is
                // filtered (<200 rows) instead of a fixed wait; timeout is a
                // safe fallback - findChatRow correctness is unaffected.
                if let tbl = AXHelpers.chatListTable(mainWindow) {
                    _ = AXHelpers.poll(timeout: 1.2) { AXHelpers.children(tbl).count < 200 }
                } else {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                stage("searchFilter")
            }
        }

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(chatName)
        }

        stage("activate+window+tab")
        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }

        stage("findRow")
        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.05)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            opened = AXHelpers.poll(timeout: 1.5) {
                AXHelpers.windows(app).contains { AXHelpers.identifier($0) != "Main Window" }
            }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
        }

        // 7. Wait for the chat window to appear
        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.1)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" })
            if chatWindow != nil { break }
        }
        stage("openChatWindow")
        guard let chatWindow else {
            throw AutomationError.inputFieldNotFound
        }

        // 8. Find the message input field
        guard let inputField = findInputField(in: chatWindow) else {
            throw AutomationError.inputFieldNotFound
        }

        // 9. Focus and type the message
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.1)
        AXHelpers.clickElement(inputField)
        // Proceed as soon as the input reports focus (fallback: short wait).
        if !AXHelpers.poll(timeout: 0.5, { AXHelpers.boolAttribute(inputField, kAXFocusedAttribute as String) == true }) {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if AXHelpers.setValue(inputField, message) {
            Thread.sleep(forTimeInterval: 0.05)
            AXHelpers.pressKey(keyCode: 36) // Return key
        } else {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AXHelpers.typeText(message)
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        }

        stage("typed+enter")
        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
        if let sf = searchField { _ = AXHelpers.setValue(sf, "") }
        stage("done")
    }

    /// Find the message input AXTextArea in a chat window.
    /// The input is in a top-level AXScrollArea that does NOT contain an AXTable (messages).
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the input one doesn't
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                // This scroll area should contain the input AXTextArea
                for subchild in AXHelpers.children(child) {
                    if AXHelpers.role(subchild) == "AXTextArea" {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    case inputFieldNotFound
    case sendFailed(String)

    public var description: String {
        switch self {
        case .noWindows:
            return "KakaoTalk has no open windows"
        case .chatNotFound(let name):
            return "Chat '\(name)' not found in the chat list"
        case .inputFieldNotFound:
            return "Could not find the message input field"
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
