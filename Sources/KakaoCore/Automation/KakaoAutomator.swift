import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        try sendOrPrepare(to: chatName, message: message, selfChat: selfChat, prepareOnly: false)
    }

    /// NEW prepare flow: open the chat, TYPE the message into its input box,
    /// then STOP. No Enter, no close: the text sits unsent in the chat window
    /// awaiting an explicit later go-ahead (see sendPrepared). Returns the
    /// verified input-field value.
    @discardableResult
    public func prepareMessage(to chatName: String, message: String, selfChat: Bool = false) throws -> String {
        try sendOrPrepare(to: chatName, message: message, selfChat: selfChat, prepareOnly: true)
        // Re-read the still-open chat window's input as proof.
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)
        if let w = chatWindowElement(app, chatName: chatName, selfChat: selfChat),
           let input = findInputField(in: w), let v = AXHelpers.value(input) {
            return v
        }
        return message
    }

    /// Activate KakaoTalk, raise the prepared chat window, CLICK its message
    /// input, and verify BOTH focus and exact input value. This is everything
    /// sendPrepared does BEFORE Enter, factored out so it can be exercised
    /// on its own (`kakaocli send --focus-prepared`) with zero send risk:
    /// this function never presses Enter/Return and never types.
    /// Returns the verified input value. Throws (refusing any later Enter)
    /// if the window/input is missing, focus is not reported, or the value
    /// does not exactly match.
    @discardableResult
    public func focusPrepared(to chatName: String, message: String, selfChat: Bool = false) throws -> String {
        let (window, input) = try focusPreparedInput(to: chatName, message: message, selfChat: selfChat)
        _ = window; _ = input
        return AXHelpers.value(input) ?? ""
    }

    private func focusPreparedInput(to chatName: String, message: String, selfChat: Bool) throws -> (AXUIElement, AXUIElement) {
        let start = Date()
        func stage(_ name: String) {
            fputs("[kakaocli] focusPrepared stage=\(name) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s\n", stderr)
        }
        // 1. ACTIVATE the app first. The 2026-10-19 failed attempt skipped
        //    this: AX-raise + AX-focus alone do not make KakaoTalk frontmost,
        //    so the CGEvent Enter went nowhere (draft left untouched).
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        stage("activateApp")
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)
        guard let w = chatWindowElement(app, chatName: chatName, selfChat: selfChat) else {
            throw AutomationError.inputFieldNotFound
        }
        // 2. Raise the prepared chat window, then find its input
        //    (AXTextArea desc "메시지 입력" / id _NS:51 via findInputField).
        _ = AXHelpers.performAction(w, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.1)
        guard let input = findInputField(in: w) else { throw AutomationError.inputFieldNotFound }
        stage("raise+findInput")
        // 3. Pre-click exact-match check: refuse before touching anything.
        guard AXHelpers.value(input) == message else {
            throw AutomationError.sendFailed("prepared input does not exactly match the expected message; refusing")
        }
        // 4. CLICK the input (real mouse click, as in the main send path --
        //    AX focus alone was not enough) and poll for reported focus.
        AXHelpers.clickElement(input)
        let focused = AXHelpers.poll(timeout: 1.0) {
            AXHelpers.boolAttribute(input, kAXFocusedAttribute as String) == true
        }
        if !focused { _ = AXHelpers.focus(input) }
        let focusOK = AXHelpers.poll(timeout: 0.5) {
            AXHelpers.boolAttribute(input, kAXFocusedAttribute as String) == true
        }
        stage("click+focus focus=\(focusOK)")
        guard focusOK else {
            throw AutomationError.sendFailed("prepared input did not report focus after click; refusing to proceed toward Enter")
        }
        // 5. Post-click exact-match re-verification (click must not have
        //    altered the draft).
        guard AXHelpers.value(input) == message else {
            throw AutomationError.sendFailed("prepared input changed after click; refusing to proceed toward Enter")
        }
        stage("verified")
        return (w, input)
    }

    /// Follow-up to prepareMessage: press Enter on an already-prepared chat
    /// window ONLY if its input still exactly matches `message`. Never types.
    /// All activation/raise/click/focus/value checks live in
    /// focusPreparedInput above; Enter is pressed only after they all pass,
    /// and the value is checked one final time immediately before it.
    public func sendPrepared(to chatName: String, message: String, selfChat: Bool = false) throws {
        let (w, input) = try focusPreparedInput(to: chatName, message: message, selfChat: selfChat)
        guard AXHelpers.value(input) == message else {
            throw AutomationError.sendFailed("prepared input does not exactly match the message to send; refusing to press Enter")
        }
        AXHelpers.pressKey(keyCode: 36) // Return: send the prepared text
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(w)
    }

    private func chatWindowElement(_ app: AXUIElement, chatName: String, selfChat: Bool) -> AXUIElement? {
        let wins = AXHelpers.windows(app).filter { AXHelpers.identifier($0) != "Main Window" }
        if !selfChat, let exact = wins.first(where: { AXHelpers.title($0) == chatName }) { return exact }
        return wins.first
    }

    private func sendOrPrepare(to chatName: String, message: String, selfChat: Bool = false, prepareOnly: Bool) throws {
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
            // FAST PATH (user feedback 2026-10-19: magnifier hunt is too slow):
            // reuse the already-present search field (_NS:20) directly. Only
            // if no field exists at all do we press the "검색" magnifier, and
            // then poll with early exit instead of a fixed wait.
            var existingField = AXHelpers.findSearchField(mainWindow)
                ?? AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
            if existingField == nil, let btn = AXHelpers.findFirstByDescription(mainWindow, desc: "검색", maxDepth: 3) {
                _ = AXHelpers.performAction(btn, kAXPressAction as String)
                _ = AXHelpers.poll(timeout: 1.5) {
                    existingField = AXHelpers.findSearchField(mainWindow)
                        ?? AXHelpers.findFirstByRoles(mainWindow, roles: ["AXTextField", "AXSearchField"], maxDepth: 4)
                    return existingField != nil
                }
            }
            if let field = existingField {
                searchField = field
                let query = chatName.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? chatName
                // Already filtered to this query (e.g. left over from a prior
                // attempt): do not focus/re-type at all.
                if AXHelpers.value(field) != String(query) {
                    _ = AXHelpers.focus(field)
                    if !AXHelpers.setValue(field, String(query)) {
                        AXHelpers.clickElement(field)
                        AXHelpers.typeText(String(query))
                    }
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
        //    DIAGNOSIS (2026-10-19, JHs failure): after the search filter the
        //    SEARCH FIELD still had keyboard focus, so Enter was delivered to
        //    it and no chat window ever opened; the code then burned 1.5s in
        //    that poll + 0.3s scroll + a double-click whose two clicks both
        //    carried clickState=2, and finally a fixed 5s/0.1s window poll
        //    (stage total 7.82s) before giving up with the misleading
        //    inputFieldNotFound. Fix: give the TABLE focus before Enter.
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            _ = AXHelpers.focus(table)
            Thread.sleep(forTimeInterval: 0.05)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            opened = AXHelpers.poll(timeout: 2.0) {
                self.chatWindowElement(app, chatName: chatName, selfChat: selfChat) != nil
            }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.1)
            }
            AXHelpers.doubleClickElement(row)
            opened = AXHelpers.poll(timeout: 2.0) {
                self.chatWindowElement(app, chatName: chatName, selfChat: selfChat) != nil
            }
        }

        // 7/8. Wait for the chat window AND its message input field, polling
        // with early exit and RE-FETCHING the window each iteration (the AX
        // element/window contents are not ready the instant the window
        // appears: the old code called findInputField exactly once, which
        // is the second half of why JHs failed). Prefer the window whose
        // title is the room name; raise it before inspecting.
        stage("openChatWindow")
        var chatWindow: AXUIElement?
        var inputField: AXUIElement?
        _ = AXHelpers.poll(timeout: 4.0) {
            guard let w = self.chatWindowElement(app, chatName: chatName, selfChat: selfChat) else { return false }
            chatWindow = w
            if inputField == nil { _ = AXHelpers.performAction(w, kAXRaiseAction as String) }
            inputField = self.findInputField(in: w)
            return inputField != nil
        }
        stage("findInputField")
        guard let chatWindow, let inputField else {
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

        // Type the message. setValue is preferred; if it does not stick
        // (readback empty/different), fall back to real keystrokes.
        var typedViaSetValue = AXHelpers.setValue(inputField, message)
        if typedViaSetValue {
            Thread.sleep(forTimeInterval: 0.05)
            if AXHelpers.value(inputField) != message { typedViaSetValue = false }
        }
        if !typedViaSetValue {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.05)
            AXHelpers.typeText(message)
            Thread.sleep(forTimeInterval: 0.1)
        }

        if prepareOnly {
            // PREPARE: verify the exact text is sitting in the input, then
            // STOP. No Enter, do not close the chat window, do not clear the
            // search field: everything stays as the user will see it when
            // asked "보낼까요?".
            let ok = AXHelpers.poll(timeout: 1.0) { AXHelpers.value(inputField) == message }
            stage("prepared-unsent")
            guard ok else {
                // Leave no partial draft behind on failure if we can clear it.
                _ = AXHelpers.setValue(inputField, "")
                throw AutomationError.sendFailed("prepare failed: input value did not equal the message")
            }
            return
        }

        AXHelpers.pressKey(keyCode: 36) // Return key
        stage("typed+enter")
        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
        if let sf = searchField { _ = AXHelpers.setValue(sf, "") }
        stage("done")
    }

    /// Find the message input AXTextArea in a chat window.
    /// Live JHs window (verified 2026-10-19): AXWindow(title=room, id=_NS:443)
    ///   > AXScrollArea(id=_NS:47) > AXTextArea(id=_NS:51, desc="메시지 입력")
    /// while the message list is AXScrollArea(id=_NS:29) > AXTable(id=_NS:33)
    /// and contains many other AXTextAreas (message bubbles). So: prefer the
    /// text area described "메시지 입력" / id _NS:51, then the old heuristic
    /// (top-level scroll area without a table), never a bubble in the table.
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        if let byDesc = findInputDescendant(window, depth: 0) { return byDesc }
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

    private func findInputDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 4 else { return nil }
        let attrs = AXHelpers.stringAttributes(element, [kAXRoleAttribute as String, kAXIdentifierAttribute as String, kAXDescriptionAttribute as String])
        if attrs[kAXRoleAttribute as String] == "AXTextArea",
           attrs[kAXDescriptionAttribute as String] == "메시지 입력" || attrs[kAXIdentifierAttribute as String] == "_NS:51" {
            return element
        }
        for child in AXHelpers.children(element) {
            if let f = findInputDescendant(child, depth: depth + 1) { return f }
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
