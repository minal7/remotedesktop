import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let completion = SafariWebExtensionCompletion(context: context)
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8),
              let result = try? JSONDecoder().decode(SafariBridgeResult.self, from: data),
              result.schemaVersion == 1 else {
            completion.finish(accepted: false)
            return
        }

        let connection = SafariBridgeXPCClient.connection(service: SafariBridgeXPCNames.extensionService)
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in
            connection.invalidate()
            completion.finish(accepted: false)
        }) as? SafariBridgeBrokerXPC else {
            connection.invalidate()
            completion.finish(accepted: false)
            return
        }

        // Keep only the typed result envelope. Never pass arbitrary browser
        // objects, page text, credentials, or executable strings over XPC.
        guard result.taskToken.count == 32 else {
            connection.invalidate()
            completion.finish(accepted: false)
            return
        }
        remote.submitResult(json) { accepted in
            connection.invalidate()
            completion.finish(accepted: accepted)
        }
    }
}

private final class SafariWebExtensionCompletion {
    private let lock = NSLock()
    private var completed = false
    private let context: NSExtensionContext

    init(context: NSExtensionContext) {
        self.context = context
    }

    func finish(accepted: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

