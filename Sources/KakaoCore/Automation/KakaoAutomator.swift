import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message and/or image to a chat by navigating the UI.
    /// At least one of `message`/`imagePath` must be provided; if both are given and
    /// `imagePath` triggers KakaoTalk's confirmation sheet, `message` is used as the
    /// image's caption (KakaoTalk caps captions at 50 characters).
    public func sendMessage(to chatName: String, message: String?, selfChat: Bool = false, imagePath: String? = nil) throws {
        // 1. Ensure KakaoTalk is running and logged in
        let stateBefore = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

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

        // 4. Ensure we're on the Chats tab
        if let chatroomsTab = AXHelpers.findFirst(mainWindow, identifier: "chatrooms") {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(selfChat ? "self-chat (나와의 채팅)" : chatName)
        }

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

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
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
            Thread.sleep(forTimeInterval: 0.5)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.inputFieldNotFound
        }

        // 8. Find the message input field
        guard let inputField = findInputField(in: chatWindow) else {
            throw AutomationError.inputFieldNotFound
        }

        // 9. Focus and send the image and/or message
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
        AXHelpers.clickElement(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        if let imagePath {
            try sendImage(imagePath, caption: message, inputField: inputField, chatWindow: chatWindow)
        } else if let message {
            if AXHelpers.setValue(inputField, message) {
                Thread.sleep(forTimeInterval: 0.2)
                AXHelpers.pressKey(keyCode: 36) // Return key
            } else {
                _ = AXHelpers.focus(inputField)
                Thread.sleep(forTimeInterval: 0.1)
                AXHelpers.typeText(message)
                Thread.sleep(forTimeInterval: 0.2)
                AXHelpers.pressKey(keyCode: 36) // Return key
            }
        }

        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
    }

    /// Paste an image into the focused input field and send it.
    ///
    /// KakaoTalk-for-Mac's behavior after Cmd+V is inconsistent: most images (anything
    /// beyond a trivial size/dimension) open a "Clipped Image" AXSheet with an optional
    /// 50-character caption field and explicit Cancel/Send buttons; very small images have
    /// been observed sending immediately with no sheet at all. This handles both: if a
    /// sheet appears within the timeout, fill the caption (if any) and press its Send
    /// button; if no sheet appears, assume the paste already sent the image directly.
    private func sendImage(_ imagePath: String, caption: String?, inputField: AXUIElement, chatWindow: AXUIElement) throws {
        guard let image = NSImage(contentsOfFile: imagePath) else {
            throw AutomationError.sendFailed("Could not load image at '\(imagePath)'")
        }

        // Clear any stray draft text before pasting so it doesn't get sent as part of the image.
        _ = AXHelpers.setValue(inputField, "")
        _ = AXHelpers.focus(inputField)
        Thread.sleep(forTimeInterval: 0.1)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        AXHelpers.pressKey(keyCode: 9, flags: .maskCommand) // Cmd+V
        Thread.sleep(forTimeInterval: 0.3)

        var sheet: AXUIElement?
        let sheetDeadline = Date().addingTimeInterval(5.0)
        while Date() < sheetDeadline {
            if let found = AXHelpers.findAll(chatWindow, role: "AXSheet").first {
                sheet = found
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard let sheet else {
            // No confirmation sheet appeared - the paste already sent the image directly.
            return
        }

        if let caption, !caption.isEmpty {
            let truncatedCaption = String(caption.prefix(50))
            if let captionField = AXHelpers.findFirst(sheet, role: "AXTextArea", text: "Enter a brief description.") {
                if !AXHelpers.setValue(captionField, truncatedCaption) {
                    _ = AXHelpers.focus(captionField)
                    Thread.sleep(forTimeInterval: 0.1)
                    AXHelpers.typeText(truncatedCaption)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        guard let sendButton = AXHelpers.findFirst(sheet, role: "AXButton", text: "Send") else {
            throw AutomationError.sendFailed("Could not find Send button on image confirmation sheet")
        }
        _ = AXHelpers.performAction(sendButton, kAXPressAction as String)
        Thread.sleep(forTimeInterval: 0.3)
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
