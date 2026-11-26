import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import PromptUI
import SGItemListUI
import SGSimpleSettings

private struct NhCatalogGift {
    let emoji: String
    let title: String
    let slugPrefix: String
}

private let nhNftCatalog: [NhCatalogGift] = [
    NhCatalogGift(emoji: "🐸", title: "Plush Pepe", slugPrefix: "PlushPepe"),
    NhCatalogGift(emoji: "🧢", title: "Durov's Cap", slugPrefix: "DurovsCap"),
    NhCatalogGift(emoji: "🐱", title: "Scared Cat", slugPrefix: "ScaredCat"),
    NhCatalogGift(emoji: "💎", title: "Astral Shard", slugPrefix: "AstralShard"),
    NhCatalogGift(emoji: "🍷", title: "Spiced Wine", slugPrefix: "SpicedWine"),
    NhCatalogGift(emoji: "⌚️", title: "Swiss Watch", slugPrefix: "SwissWatch"),
    NhCatalogGift(emoji: "💰", title: "Loot Bag", slugPrefix: "LootBag"),
    NhCatalogGift(emoji: "🧴", title: "Perfume Bottle", slugPrefix: "PerfumeBottle"),
    NhCatalogGift(emoji: "🏆", title: "Mini Oscar", slugPrefix: "MiniOscar"),
    NhCatalogGift(emoji: "🧪", title: "Magic Potion", slugPrefix: "MagicPotion"),
    NhCatalogGift(emoji: "💠", title: "Ion Gem", slugPrefix: "IonGem"),
    NhCatalogGift(emoji: "🔮", title: "Crystal Ball", slugPrefix: "CrystalBall"),
    NhCatalogGift(emoji: "💍", title: "Signet Ring", slugPrefix: "SignetRing"),
    NhCatalogGift(emoji: "💀", title: "Electric Skull", slugPrefix: "ElectricSkull"),
    NhCatalogGift(emoji: "🚬", title: "Vintage Cigar", slugPrefix: "VintageCigar"),
    NhCatalogGift(emoji: "🌹", title: "Eternal Rose", slugPrefix: "EternalRose"),
    NhCatalogGift(emoji: "🍑", title: "Precious Peach", slugPrefix: "PreciousPeach"),
    NhCatalogGift(emoji: "🧸", title: "Toy Bear", slugPrefix: "ToyBear"),
    NhCatalogGift(emoji: "💋", title: "Kissed Frog", slugPrefix: "KissedFrog"),
    NhCatalogGift(emoji: "💍", title: "Diamond Ring", slugPrefix: "DiamondRing")
]

private enum NhAdminSection: Int32 {
    case target, currentNfts, catalog, badges, auth
}

private enum NhAdminAction: Equatable {
    case setTargetId
    case clearNfts
    case customNft
    case catalogNft(String, String)
    case grantBadge
    case removeBadge
    case setToken
}

private final class NhAdminArguments {
    let perform: (NhAdminAction) -> Void
    init(perform: @escaping (NhAdminAction) -> Void) {
        self.perform = perform
    }
}

private enum NhAdminEntry: ItemListNodeEntry {
    case header(id: Int, section: NhAdminSection, text: String)
    case footer(id: Int, section: NhAdminSection, text: String)
    case link(id: Int, section: NhAdminSection, action: NhAdminAction, symbol: String, tint: UIColor, title: String, label: String)
    case info(id: Int, section: NhAdminSection, title: String, label: String)
    case destructive(id: Int, section: NhAdminSection, action: NhAdminAction, title: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, s, _), let .footer(_, s, _), let .link(_, s, _, _, _, _, _), let .info(_, s, _, _), let .destructive(_, s, _, _):
            return s.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case let .header(id, _, _), let .footer(id, _, _), let .link(id, _, _, _, _, _, _), let .info(id, _, _, _), let .destructive(id, _, _, _):
            return id
        }
    }

    static func <(lhs: NhAdminEntry, rhs: NhAdminEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NhAdminArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .link(_, _, action, symbol, tint, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: ayuGramRowIcon(symbol, color: tint), title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.perform(action)
            })
        case let .info(_, _, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {})
        case let .destructive(_, _, action, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.perform(action)
            })
        }
    }
}

public func netherhillAdminController(context: AccountContext) -> ViewController {
    var presentController: ((ViewController) -> Void)?
    let statePromise = ValuePromise<(Int64, [String], Bool)>((AyuGramUpdates.developerId, [], false), ignoreRepeated: false)

    func reloadTarget(_ targetId: Int64) {
        statePromise.set((targetId, [], true))
        guard let url = URL(string: AyuGramSecurity.relayURL + "/profile?ids=\(targetId)") else {
            statePromise.set((targetId, [], false))
            return
        }
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0), completionHandler: { data, _, _ in
            session.finishTasksAndInvalidate()
            var nfts: [String] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]],
               let first = items.first,
               let rawNfts = first["nfts"] as? [[String: Any]] {
                for item in rawNfts {
                    if let slug = item["slug"] as? String, !slug.isEmpty {
                        nfts.append(slug + ((item["pinned"] as? Bool) == true ? " · Закреплена" : ""))
                    } else if let col = item["collection"] as? String, !col.isEmpty {
                        let num = (item["number"] as? Int) ?? 1
                        nfts.append("\(col) #\(num)")
                    }
                }
            }
            DispatchQueue.main.async {
                statePromise.set((targetId, nfts, false))
            }
        }).resume()
    }

    var currentTargetId: Int64 = AyuGramUpdates.developerId
    reloadTarget(currentTargetId)

    let arguments = NhAdminArguments(perform: { action in
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let showResult: (Bool) -> Void = { ok in
            if ok {
                reloadTarget(currentTargetId)
            }
            presentController?(textAlertController(context: context, title: nil, text: ok ? "Выполнено!" : "Ошибка. Проверь Admin Token и подключение к серверу.", actions: [TextAlertAction(type: .defaultAction, title: data.strings.Common_OK, action: {})]))
        }

        switch action {
        case .setTargetId:
            presentController?(promptController(context: context, text: "Telegram User ID получателя", value: String(currentTargetId), placeholder: "6891746399", characterLimit: 24, apply: { val in
                if let val, let uid = Int64(val.trimmingCharacters(in: .whitespacesAndNewlines)), uid > 0 {
                    currentTargetId = uid
                    reloadTarget(uid)
                }
            }))
        case .clearNfts:
            AyuGramBadgeSync.shared.adminGrantNft(targetId: currentTargetId, clear: true, completion: showResult)
        case .customNft:
            presentController?(promptController(context: context, text: "Введи Slug (например PlushPepe-1)", value: "", placeholder: "PlushPepe-1", characterLimit: 80, apply: { val in
                guard let slug = val?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else { return }
                AyuGramBadgeSync.shared.adminGrantNft(targetId: currentTargetId, slug: slug, completion: showResult)
            }))
        case let .catalogNft(prefix, title):
            presentController?(promptController(context: context, text: "Выдать \(title) (#номер) для ID \(currentTargetId)", value: "1", placeholder: "Номер, напр. 1 или 777", characterLimit: 12, apply: { val in
                guard let num = val.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), num > 0 else { return }
                AyuGramBadgeSync.shared.adminGrantNft(targetId: currentTargetId, slug: "\(prefix)-\(num)", completion: showResult)
            }))
        case .grantBadge:
            presentController?(promptController(context: context, text: "SF Symbol или эмодзи для ID \(currentTargetId)", value: "crown.fill", placeholder: "crown.fill или 🔥", characterLimit: 40, apply: { val in
                guard let val = val?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else { return }
                let isEmoji = val.unicodeScalars.contains(where: { $0.value > 127 })
                AyuGramBadgeSync.shared.adminGrantBadge(targetId: currentTargetId, symbol: isEmoji ? "crown.fill" : val, emoji: isEmoji ? val : "", completion: showResult)
            }))
        case .removeBadge:
            AyuGramBadgeSync.shared.adminGrantBadge(targetId: currentTargetId, remove: true, completion: showResult)
        case .setToken:
            presentController?(promptController(context: context, text: "Admin Token сервера NETHERHILL", value: AyuGramBadgeSync.shared.adminToken, placeholder: "Token", characterLimit: 200, apply: { val in
                if let val {
                    AyuGramBadgeSync.shared.adminToken = val
                    reloadTarget(currentTargetId)
                }
            }))
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { data, state -> (ItemListControllerState, (ItemListNodeState, NhAdminArguments)) in
        let (targetId, nfts, loading) = state
        var entries: [NhAdminEntry] = []

        entries.append(.header(id: 1, section: .target, text: "ПОЛУЧАТЕЛЬ"))
        entries.append(.link(id: 2, section: .target, action: .setTargetId, symbol: "person.crop.circle.fill", tint: AyuGramRowColor.red, title: "User ID", label: String(targetId)))

        entries.append(.header(id: 10, section: .currentNfts, text: "ВЫДАННЫЕ NFT (\(nfts.count))"))
        if loading {
            entries.append(.info(id: 11, section: .currentNfts, title: "Загрузка с сервера...", label: ""))
        } else if nfts.isEmpty {
            entries.append(.info(id: 11, section: .currentNfts, title: "Нет выданных NFT", label: "0"))
        } else {
            for (idx, nftName) in nfts.enumerated() {
                let parts = nftName.components(separatedBy: " · ")
                entries.append(.info(id: 20 + idx, section: .currentNfts, title: parts[0], label: parts.count > 1 ? parts[1] : ""))
            }
            entries.append(.destructive(id: 90, section: .currentNfts, action: .clearNfts, title: "Очистить все NFT у \(targetId)"))
        }

        entries.append(.header(id: 100, section: .catalog, text: "КАТАЛОГ ПОДАРКОВ (ВЫДАЧА)"))
        entries.append(.link(id: 101, section: .catalog, action: .customNft, symbol: "plus.circle.fill", tint: AyuGramRowColor.purple, title: "Ввести свой Slug вручную", label: ""))
        for (idx, item) in nhNftCatalog.enumerated() {
            entries.append(.link(id: 110 + idx, section: .catalog, action: .catalogNft(item.slugPrefix, item.title), symbol: "gift.fill", tint: AyuGramRowColor.orange, title: "\(item.emoji) \(item.title)", label: item.slugPrefix))
        }

        entries.append(.header(id: 300, section: .badges, text: "ОСОБЫЕ БЕЙДЖИ"))
        entries.append(.link(id: 301, section: .badges, action: .grantBadge, symbol: "checkmark.seal.fill", tint: AyuGramRowColor.blue, title: "Выдать особый бейдж", label: ""))
        entries.append(.destructive(id: 302, section: .badges, action: .removeBadge, title: "Снять бейдж у \(targetId)"))

        entries.append(.header(id: 400, section: .auth, text: "АВТОРИЗАЦИЯ СЕРВЕРА"))
        entries.append(.link(id: 401, section: .auth, action: .setToken, symbol: "key.fill", tint: AyuGramRowColor.gray, title: "Admin Token", label: AyuGramBadgeSync.shared.adminToken.isEmpty ? "Не задан" : "Задан ✓"))

        let state = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text("Админ-панель NETHERHILL"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks, animateChanges: true)
        return (state, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentController = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}
