import Foundation
import TelegramCore
import AccountContext
import TelegramPresentationData
import SGSimpleSettings

public func ayuGramFakeNftViewScreen(context: AccountContext, gift: StarGift.UniqueGift) -> GiftViewScreen {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var modelFileId: Int64?
    for attribute in gift.attributes {
        if case let .model(_, file, _, _) = attribute {
            modelFileId = file.fileId.id
            break
        }
    }
    let action: GiftViewScreen.CustomAction
    if let fileId = modelFileId {
        let peerId = context.account.peerId.id._internalGetInt64Value()
        action = GiftViewScreen.CustomAction(title: "Поставить в эмодзи-статус", action: {
            AyuGramSettings.shared.updateClient { $0.localPremium = true }
            AyuGramSettings.shared.setLocalStatus(peerId: peerId, status: AyuGramLocalStatus(fileId: fileId, expirationDate: nil))
        })
    } else {
        action = GiftViewScreen.CustomAction(title: presentationData.strings.Common_Close, action: {})
    }
    return GiftViewScreen(
        context: context,
        subject: .uniqueGift(gift.withResellAmounts(nil), nil),
        customAction: action,
        ayuFakeNft: true
    )
}
