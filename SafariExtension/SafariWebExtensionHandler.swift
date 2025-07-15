// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "com.sushitrain.SafariExtension", category: "ExtensionHandler")
    private let historyStore = BrowserHistoryStore()
    
    func beginRequest(with context: NSExtensionContext) {
        guard let message = context.inputItems.first as? NSExtensionItem,
              let userInfo = message.userInfo as? [String: Any],
              let action = userInfo["action"] as? String else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        switch action {
        case "logHistory":
            handleLogHistory(userInfo: userInfo, context: context)
        case "updateDuration":
            handleUpdateDuration(userInfo: userInfo, context: context)
        default:
            logger.warning("Unknown action: \(action)")
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
    
    private func handleLogHistory(userInfo: [String: Any], context: NSExtensionContext) {
        guard let data = userInfo["data"] as? [String: Any],
              let url = data["url"] as? String,
              let title = data["title"] as? String,
              let timestampStr = data["timestamp"] as? String else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        // Parse timestamp
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.date(from: timestampStr) ?? Date()
        
        // Create history entry
        let entry = BrowserHistoryEntry(
            url: url,
            title: title,
            timestamp: timestamp,
            referrer: data["referrer"] as? String
        )
        
        // Store it
        historyStore.addEntry(entry)
        
        // Send success response
        let response = NSExtensionItem()
        response.userInfo = ["success": true]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
    
    private func handleUpdateDuration(userInfo: [String: Any], context: NSExtensionContext) {
        // For now, we'll skip duration tracking in v1
        // Could be implemented by updating the existing entry
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}