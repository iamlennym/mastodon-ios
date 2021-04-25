//
//  NotificationService.swift
//  NotificationService
//
//  Created by MainasuK Cirno on 2021-4-23.
//

import UserNotifications
import CommonOSLog
import CryptoKit
import AlamofireImage
import Base85
import Keys

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        if let bestAttemptContent = bestAttemptContent {
            // Modify the notification content here...
            os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s", ((#file as NSString).lastPathComponent), #line, #function)

            let privateKey = AppSecret.default.notificationPrivateKey!
            
            guard let encodedPayload = bestAttemptContent.userInfo["p"] as? String,
                  let payload = Data(base85Encoded: encodedPayload, options: [], encoding: .z85) else {
                os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s: invalid payload", ((#file as NSString).lastPathComponent), #line, #function)
                contentHandler(bestAttemptContent)
                return
            }
            
            guard let encodedPublicKey = bestAttemptContent.userInfo["k"] as? String,
                  let publicKey = NotificationService.publicKey(encodedPublicKey: encodedPublicKey) else {
                os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s: invalid public key", ((#file as NSString).lastPathComponent), #line, #function)
                contentHandler(bestAttemptContent)
                return
            }
            
            guard let encodedSalt = bestAttemptContent.userInfo["s"] as? String,
                let salt = Data(base85Encoded: encodedSalt, options: [], encoding: .z85) else {
                os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s: invalid salt", ((#file as NSString).lastPathComponent), #line, #function)
                contentHandler(bestAttemptContent)
                return
            }
            
            let auth = AppSecret.default.notificationAuth
            guard let plaintextData = NotificationService.decrypt(payload: payload, salt: salt, auth: auth, privateKey: privateKey, publicKey: publicKey),
                  let notification = try? JSONDecoder().decode(MastodonNotification.self, from: plaintextData) else {
                contentHandler(bestAttemptContent)
                return
            }
            
            bestAttemptContent.title = notification.title
            bestAttemptContent.subtitle = ""
            bestAttemptContent.body = notification.body
            
            if let urlString = notification.icon, let url = URL(string: urlString) {
                let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notification-attachments")
                try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                let filename = url.lastPathComponent
                let fileURL = temporaryDirectoryURL.appendingPathComponent(filename)

                ImageDownloader.default.download(URLRequest(url: url), completion: { [weak self] response in
                    guard let _ = self else { return }
                    switch response.result {
                    case .failure(let error):
                        os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s: download image %s fail: %s", ((#file as NSString).lastPathComponent), #line, #function, url.debugDescription, error.localizedDescription)
                    case .success(let image):
                        os_log(.info, log: .debug, "%{public}s[%{public}ld], %{public}s: download image %s success", ((#file as NSString).lastPathComponent), #line, #function, url.debugDescription)
                        try? image.pngData()?.write(to: fileURL)
                        if let attachment = try? UNNotificationAttachment(identifier: filename, url: fileURL, options: nil) {
                            bestAttemptContent.attachments = [attachment]
                        }
                    }
                    contentHandler(bestAttemptContent)
                })
            } else {
                contentHandler(bestAttemptContent)
            }
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

}

extension NotificationService {
    static func publicKey(encodedPublicKey: String) -> P256.KeyAgreement.PublicKey? {
        guard let publicKeyData = Data(base85Encoded: encodedPublicKey, options: [], encoding: .z85) else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
    }
}
