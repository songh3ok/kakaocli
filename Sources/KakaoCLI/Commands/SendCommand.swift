import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation"
    )

    @Argument(help: "Chat name to send to (substring match), or any value with --self")
    var chat: String

    @Argument(help: "Message text to send")
    var message: String

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    @Flag(name: .customLong("prepare"), help: "Type the message into the chat input and STOP: do not press Enter, leave the chat window open awaiting confirmation")
    var prepare = false

    @Flag(name: .customLong("send-prepared"), help: "Press Enter on a message already typed by --prepare, only if the input still exactly matches the message argument")
    var sendPrepared = false

    @Flag(name: .customLong("focus-prepared"), help: "Activate KakaoTalk, raise the prepared chat, click its input and verify focus + exact value, then STOP before Enter (cannot send)")
    var focusPrepared = false

    func run() throws {
        let automator = KakaoAutomator()
        let target = selfChat ? "self-chat" : chat
        if [prepare, sendPrepared, focusPrepared].filter({ $0 }).count > 1 {
            print("refusing: --prepare, --send-prepared and --focus-prepared are mutually exclusive")
            throw ExitCode.failure
        }
        if dryRun {
            if prepare {
                print("DRY RUN (prepare): Would open '\(target)', type into its input, and STOP without sending: \(message)")
            } else if focusPrepared {
                print("DRY RUN (focus-prepared): Would activate KakaoTalk, click the '\(target)' input and verify focus/value, stopping before Enter: \(message)")
            } else if sendPrepared {
                print("DRY RUN (send-prepared): Would press Enter in '\(target)' only if its input exactly equals: \(message)")
            } else {
                print("DRY RUN: Would send to '\(target)': \(message)")
                print("Steps: activate KakaoTalk → find chat '\(target)' → type message → press Enter")
            }
            return
        }
        if prepare {
            let value = try automator.prepareMessage(to: chat, message: message, selfChat: selfChat)
            print("PREPARED (NOT SENT) to '\(target)': input now contains: \(value)")
            print("The chat window is left open with the text unsent. Send it only after explicit confirmation via: kakaocli send --send-prepared")
            return
        }
        if focusPrepared {
            let value = try automator.focusPrepared(to: chat, message: message, selfChat: selfChat)
            print("FOCUSED PREPARED (NOT SENT, no Enter pressed) for '\(target)': focused input exactly contains: \(value)")
            print("Stopped before Enter. Send later only after explicit confirmation via: kakaocli send --send-prepared")
            return
        }
        if sendPrepared {
            try automator.sendPrepared(to: chat, message: message, selfChat: selfChat)
            print("Prepared message sent to '\(target)'.")
            return
        }
        try automator.sendMessage(to: chat, message: message, selfChat: selfChat)
        print("Message sent to '\(target)'.")
    }
}
