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

    @Argument(help: "Message text to send. Optional if --image is given, in which case it's used as the image's caption.")
    var message: String?

    @Option(name: .long, help: "Path to an image file to send")
    var image: String?

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    func validate() throws {
        if message == nil && image == nil {
            throw ValidationError("Provide a message, --image <path>, or both.")
        }
    }

    func run() throws {
        let automator = KakaoAutomator()
        let target = selfChat ? "self-chat" : chat
        if dryRun {
            if let image {
                let captionNote = message.map { " (caption: \($0))" } ?? ""
                print("DRY RUN: Would send image '\(image)' to '\(target)'\(captionNote)")
                print("Steps: activate KakaoTalk → find chat '\(target)' → paste image → confirm send")
            } else {
                print("DRY RUN: Would send to '\(target)': \(message ?? "")")
                print("Steps: activate KakaoTalk → find chat '\(target)' → type message → press Enter")
            }
            return
        }
        try automator.sendMessage(to: chat, message: message, selfChat: selfChat, imagePath: image)
        if let image {
            print("Image '\(image)' sent to '\(target)'.")
        } else {
            print("Message sent to '\(target)'.")
        }
    }
}
