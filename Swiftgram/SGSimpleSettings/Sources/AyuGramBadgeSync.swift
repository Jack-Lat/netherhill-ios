import Foundation

public struct AyuGramBadgePayment: Equatable {
    public var cryptoBot: String
    public var xRocket: String
    public var tonAddress: String
    public var tonAmount: String
    public var tonComment: String
    public var tonURL: String
    public var tonOpen: String

    public var hasTon: Bool {
        return !self.tonAddress.isEmpty && !self.tonAmount.isEmpty && !self.tonURL.isEmpty
    }
}

public final class AyuGramBadgeSync {
    public static let shared = AyuGramBadgeSync()

    private let lock = NSLock()
    private var lastRefresh: Double = 0.0
    private var lastPresence: Double = 0.0
    private var lastPresenceAccount: Int64 = 0
    private var refreshing = false
    private let secretKey = "ayugram.badges.secret"
    private let presenceEnabledKey = "netherhill.presence.enabled"
    private let adminTokenKey = "netherhill.admin.token"
    public private(set) var payURL = ""
    public private(set) var price = "0"
    public private(set) var payment: AyuGramBadgePayment?

    public var isPresenceEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: self.presenceEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: self.presenceEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.presenceEnabledKey)
            if newValue, self.lastPresenceAccount > 0 {
                self.sendPresence(accountId: self.lastPresenceAccount, force: true)
            }
        }
    }

    public var adminToken: String {
        get {
            return UserDefaults.standard.string(forKey: self.adminTokenKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: self.adminTokenKey)
        }
    }

    public func start() {
        AyuGramClientBadges.shared.refreshHandler = { [weak self] force in
            self?.refresh(force: force)
        }
        AyuGramClientBadges.shared.presenceHandler = { [weak self] accountId in
            self?.sendPresence(accountId: accountId, force: false)
        }
        self.refresh(force: false)
    }

    public func sendPresence(accountId: Int64, force: Bool = false) {
        guard AyuGramClientBadges.valid(accountId), !AyuGramSecurity.relayURL.isEmpty else {
            return
        }
        self.lock.lock()
        self.lastPresenceAccount = accountId
        let now = Date().timeIntervalSince1970
        if !self.isPresenceEnabled || (!force && now - self.lastPresence < 3600.0) {
            self.lock.unlock()
            return
        }
        self.lastPresence = now
        self.lock.unlock()
        self.post("/nh/presence", ["id": String(accountId)], completion: { _, _ in })
    }

    public func refresh(force: Bool = false) {
        guard !AyuGramSecurity.relayURL.isEmpty else {
            return
        }
        lock.lock()
        let now = Date().timeIntervalSince1970
        if refreshing || (!force && now - lastRefresh < 120.0) {
            lock.unlock()
            return
        }
        refreshing = true
        lastRefresh = now
        lock.unlock()
        guard let url = URL(string: AyuGramSecurity.relayURL + "/badges") else {
            self.lock.lock()
            self.refreshing = false
            self.lock.unlock()
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request, completionHandler: { data, response, _ in
            session.finishTasksAndInvalidate()
            self.lock.lock()
            self.refreshing = false
            self.lock.unlock()
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["items"] as? [[String: Any]] else {
                return
            }
            var updated: [Int64: AyuGramCustomBadge] = [:]
            for item in items.prefix(5000) {
                guard let idText = item["id"] as? String, let id = Int64(idText), AyuGramClientBadges.valid(id), let raw = item["b"], let rawData = try? JSONSerialization.data(withJSONObject: raw), var badge = try? JSONDecoder().decode(AyuGramCustomBadge.self, from: rawData) else {
                    continue
                }
                badge.enabled = true
                updated[id] = badge
            }
            AyuGramClientBadges.shared.replaceSupporters(updated)
        }).resume()
    }

    var secret: String {
        if let value = UserDefaults.standard.string(forKey: self.secretKey), value.count >= 24 {
            return value
        }
        let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(value, forKey: self.secretKey)
        return value
    }

    private func post(_ path: String, _ body: [String: Any], admin: Bool = false, completion: @escaping (Int, [String: Any]) -> Void) {
        guard !AyuGramSecurity.relayURL.isEmpty, let url = URL(string: AyuGramSecurity.relayURL + path), let data = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async {
                completion(0, [:])
            }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if admin && !self.adminToken.isEmpty {
            request.setValue("Bearer " + self.adminToken, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request, completionHandler: { data, response, _ in
            session.finishTasksAndInvalidate()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            DispatchQueue.main.async {
                completion(status, object)
            }
        }).resume()
    }

    public func adminGrantBadge(targetId: Int64, symbol: String = "crown.fill", emoji: String = "", topHex: String = "E82024", bottomHex: String = "7A0C10", remove: Bool = false, completion: @escaping (Bool) -> Void) {
        var payload: [String: Any] = ["id": String(targetId)]
        if remove {
            payload["remove"] = true
        } else {
            payload["symbol"] = symbol
            payload["emoji"] = emoji
            payload["top"] = topHex
            payload["bottom"] = bottomHex
        }
        self.post("/admin/badge", payload, admin: true, completion: { status, _ in
            if status == 200 {
                self.refresh(force: true)
            }
            completion(status == 200)
        })
    }

    public func adminGrantNft(targetId: Int64, slug: String = "", collection: String = "", number: Int = 1, clear: Bool = false, completion: @escaping (Bool) -> Void) {
        var payload: [String: Any] = ["id": String(targetId)]
        if clear {
            payload["clear"] = true
        } else if !slug.isEmpty {
            payload["slug"] = slug
            payload["pinned"] = true
        } else {
            payload["collection"] = collection
            payload["number"] = number
            payload["pinned"] = true
        }
        self.post("/admin/nft", payload, admin: true, completion: { status, _ in
            completion(status == 200)
        })
    }

    private func decode(_ raw: Any?) -> AyuGramCustomBadge {
        if let raw, let data = try? JSONSerialization.data(withJSONObject: raw), var badge = try? JSONDecoder().decode(AyuGramCustomBadge.self, from: data) {
            badge.enabled = true
            return badge
        }
        var badge = AyuGramCustomBadge()
        badge.enabled = true
        return badge
    }

    private func link(_ value: Any?, schemes: [String]) -> String {
        guard let text = value as? String, text.count <= 512, schemes.contains(where: { text.hasPrefix($0) }), URL(string: text) != nil else {
            return ""
        }
        return text
    }

    private func readPayment(_ object: [String: Any], code: String) -> AyuGramBadgePayment? {
        guard let pay = object["pay"] as? [String: Any] else {
            return nil
        }
        var payment = AyuGramBadgePayment(cryptoBot: self.link(pay["cryptobot"], schemes: ["https://t.me/"]), xRocket: self.link(pay["xrocket"], schemes: ["https://t.me/"]), tonAddress: "", tonAmount: "", tonComment: code, tonURL: "", tonOpen: "")
        if let ton = pay["ton"] as? [String: Any], let address = ton["address"] as? String, address.count == 48, let amount = ton["amount"] as? String, amount.count <= 16, amount.allSatisfy({ $0.isNumber || $0 == "." }) {
            payment.tonAddress = address
            payment.tonAmount = amount
            payment.tonURL = self.link(ton["url"], schemes: ["ton://transfer/"])
            payment.tonOpen = self.link(ton["open"], schemes: ["https://app.tonkeeper.com/transfer/"])
            if payment.tonOpen.isEmpty {
                payment.tonOpen = payment.tonURL
            }
        }
        return payment
    }

    private func readState(_ status: Int, _ object: [String: Any]) -> AyuGramSupporterState {
        guard status == 200 else {
            return .failed
        }
        if (object["granted"] as? Bool) == true {
            self.payment = nil
            return .granted(self.decode(object["badge"]))
        }
        if let code = object["code"] as? String, !code.isEmpty {
            if let payment = self.readPayment(object, code: code) {
                self.payment = payment
            }
            return .pending(code)
        }
        self.payment = nil
        return .none
    }

    public func supporterStatus(accountId: Int64, completion: @escaping (AyuGramSupporterState) -> Void) {
        self.post("/badges/status", ["id": String(accountId), "secret": self.secret], completion: { status, object in
            completion(self.readState(status, object))
        })
    }

    public func requestSupporter(accountId: Int64, name: String, completion: @escaping (AyuGramSupporterState) -> Void) {
        self.post("/badges/request", ["id": String(accountId), "secret": self.secret, "name": name], completion: { status, object in
            if (object["granted"] as? Bool) == true && object["badge"] == nil {
                self.supporterStatus(accountId: accountId, completion: completion)
                return
            }
            let state = self.readState(status, object)
            if case .none = state {
                completion(.failed)
            } else {
                completion(state)
            }
        })
    }

    public func setSupporterBadge(accountId: Int64, badge: AyuGramCustomBadge, completion: @escaping (Bool) -> Void) {
        var shown = badge
        shown.enabled = true
        AyuGramClientBadges.shared.setSupporter(accountId, badge: shown)
        let payload: [String: Any] = ["symbol": badge.symbol, "emoji": badge.emoji, "shape": Int(badge.shape), "top": badge.top, "bottom": badge.bottom, "darkGlyph": badge.darkGlyph]
        self.post("/badges/set", ["id": String(accountId), "secret": self.secret, "badge": payload], completion: { status, _ in
            completion(status == 200)
        })
    }
}
