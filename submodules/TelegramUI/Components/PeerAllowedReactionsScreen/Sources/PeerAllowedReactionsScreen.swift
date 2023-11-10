import Foundation
import UIKit
import Display
import TelegramPresentationData
import ComponentFlow
import ComponentDisplayAdapters
import AppBundle
import ViewControllerComponent
import AccountContext
import TelegramCore
import Postbox
import SwiftSignalKit
import EntityKeyboard
import MultilineTextComponent
import Markdown
import ButtonComponent
import PremiumUI
import UndoUI
import BundleIconComponent
import AnimatedTextComponent

private final class ButtonSubtitleComponent: CombinedComponent {
    let count: Int
    let theme: PresentationTheme
    
    init(count: Int, theme: PresentationTheme) {
        self.count = count
        self.theme = theme
    }
    
    static func ==(lhs: ButtonSubtitleComponent, rhs: ButtonSubtitleComponent) -> Bool {
        if lhs.count != rhs.count {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        return true
    }
    
    static var body: Body {
        let icon = Child(BundleIconComponent.self)
        let text = Child(AnimatedTextComponent.self)

        return { context in
            let icon = icon.update(
                component: BundleIconComponent(
                    name: "Chat/Input/Accessory Panels/TextLockIcon",
                    tintColor: context.component.theme.list.itemCheckColors.foregroundColor.withMultipliedAlpha(0.7),
                    maxSize: CGSize(width: 10.0, height: 10.0)
                ),
                availableSize: CGSize(width: 100.0, height: 100.0),
                transition: context.transition
            )
            //TODO:localize
            var textItems: [AnimatedTextComponent.Item] = []
            textItems.append(AnimatedTextComponent.Item(id: AnyHashable(0 as Int), content: .text("Level ")))
            textItems.append(AnimatedTextComponent.Item(id: AnyHashable(1 as Int), content: .number(context.component.count, minDigits: 1)))
            textItems.append(AnimatedTextComponent.Item(id: AnyHashable(2 as Int), content: .text(" Required")))
            let text = text.update(
                component: AnimatedTextComponent(font: Font.medium(11.0), color: context.component.theme.list.itemCheckColors.foregroundColor.withMultipliedAlpha(0.7), items: textItems),
                availableSize: CGSize(width: context.availableSize.width - 20.0, height: 100.0),
                transition: context.transition
            )

            let spacing: CGFloat = 3.0
            let size = CGSize(width: icon.size.width + spacing + text.size.width, height: text.size.height)
            context.add(icon
                .position(icon.size.centered(in: CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: icon.size.width, height: size.height))).center)
            )
            context.add(text
                .position(text.size.centered(in: CGRect(origin: CGPoint(x: icon.size.width + spacing, y: 0.0), size: text.size)).center)
            )

            return size
        }
    }
}

final class PeerAllowedReactionsScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment
    
    let context: AccountContext
    let peerId: EnginePeer.Id
    let initialContent: PeerAllowedReactionsScreen.Content

    init(
        context: AccountContext,
        peerId: EnginePeer.Id,
        initialContent: PeerAllowedReactionsScreen.Content
    ) {
        self.context = context
        self.peerId = peerId
        self.initialContent = initialContent
    }

    static func ==(lhs: PeerAllowedReactionsScreenComponent, rhs: PeerAllowedReactionsScreenComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.peerId != rhs.peerId {
            return false
        }

        return true
    }
    
    final class View: UIView, UIScrollViewDelegate {
        private let scrollView: UIScrollView
        private let switchItem = ComponentView<Empty>()
        private let switchInfoText = ComponentView<Empty>()
        private var reactionsTitleText: ComponentView<Empty>?
        private var reactionsInfoText: ComponentView<Empty>?
        private var reactionInput: ComponentView<Empty>?
        private let actionButton = ComponentView<Empty>()
        
        private var reactionSelectionControl: ComponentView<Empty>?
        
        private var isUpdating: Bool = false
        
        private var component: PeerAllowedReactionsScreenComponent?
        private(set) weak var state: EmptyComponentState?
        private var environment: EnvironmentType?
        
        private var boostStatus: ChannelBoostStatus?
        private var boostStatusDisposable: Disposable?
        
        private var isEnabled: Bool = false
        private var availableReactions: AvailableReactions?
        private var enabledReactions: [EmojiComponentReactionItem]?
        private var appliedAllowedReactions: PeerAllowedReactions?
        
        private var emojiContent: EmojiPagerContentComponent?
        private var emojiContentDisposable: Disposable?
        private var caretPosition: Int?
        
        private var displayInput: Bool = false
        
        private var isApplyingSettings: Bool = false
        private var applyDisposable: Disposable?
        
        private weak var currentUndoController: UndoOverlayController?
        
        override init(frame: CGRect) {
            self.scrollView = UIScrollView()
            self.scrollView.showsVerticalScrollIndicator = true
            self.scrollView.showsHorizontalScrollIndicator = false
            self.scrollView.scrollsToTop = false
            self.scrollView.delaysContentTouches = false
            self.scrollView.canCancelContentTouches = true
            self.scrollView.contentInsetAdjustmentBehavior = .never
            self.scrollView.alwaysBounceVertical = true
            
            super.init(frame: frame)
            
            self.scrollView.delegate = self
            self.addSubview(self.scrollView)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            self.emojiContentDisposable?.dispose()
            self.applyDisposable?.dispose()
            self.boostStatusDisposable?.dispose()
        }

        func scrollToTop() {
            self.scrollView.setContentOffset(CGPoint(), animated: true)
        }
        
        func attemptNavigation(complete: @escaping () -> Void) -> Bool {
            guard let component = self.component else {
                return true
            }
            if self.isApplyingSettings {
                return true
            }
            guard var enabledReactions = self.enabledReactions else {
                return true
            }
            if !self.isEnabled {
                enabledReactions.removeAll()
            }
            guard let availableReactions = self.availableReactions else {
                return true
            }
            
            let allowedReactions: PeerAllowedReactions
            if self.isEnabled {
                if Set(availableReactions.reactions.map(\.value)) == Set(enabledReactions.map(\.reaction)) {
                    allowedReactions = .all
                } else {
                    allowedReactions = .limited(enabledReactions.map(\.reaction))
                }
            } else {
                allowedReactions = .empty
            }
            
            if self.appliedAllowedReactions != allowedReactions {
                let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                //TODO:localize
                self.environment?.controller()?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: presentationData), title: nil, text: "Save Changes?", actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .defaultAction, title: "Save", action: { [weak self] in
                        guard let self else {
                            return
                        }
                        self.applySettings()
                    })
                ]), in: .window(.root))
                
                return false
            }
            
            return true
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            self.updateScrolling(transition: .immediate)
        }
        
        private func updateScrolling(transition: Transition) {
            let navigationAlphaDistance: CGFloat = 16.0
            let navigationAlpha: CGFloat = max(0.0, min(1.0, self.scrollView.contentOffset.y / navigationAlphaDistance))
            if let controller = self.environment?.controller(), let navigationBar = controller.navigationBar {
                transition.setAlpha(layer: navigationBar.backgroundNode.layer, alpha: navigationAlpha)
                transition.setAlpha(layer: navigationBar.stripeNode.layer, alpha: navigationAlpha)
            }
        }
        
        private func applySettings() {
            guard let component = self.component else {
                return
            }
            if self.isApplyingSettings {
                return
            }
            guard var enabledReactions = self.enabledReactions else {
                return
            }
            if !self.isEnabled {
                enabledReactions.removeAll()
            }
            
            guard let availableReactions = self.availableReactions else {
                return
            }
            
            let customReactions = enabledReactions.filter({ item in
                switch item.reaction {
                case .custom:
                    return true
                case .builtin:
                    return false
                }
            })
            
            if let boostStatus = self.boostStatus, !customReactions.isEmpty, customReactions.count > boostStatus.level {
                self.displayPremiumScreen()
                return
            }
            
            self.isApplyingSettings = true
            self.state?.updated(transition: .immediate)
            
            self.applyDisposable?.dispose()
            
            let allowedReactions: PeerAllowedReactions
            if self.isEnabled {
                if Set(availableReactions.reactions.map(\.value)) == Set(enabledReactions.map(\.reaction)) {
                    allowedReactions = .all
                } else {
                    allowedReactions = .limited(enabledReactions.map(\.reaction))
                }
            } else {
                allowedReactions = .empty
            }
            self.applyDisposable = (component.context.engine.peers.updatePeerAllowedReactions(peerId: component.peerId, allowedReactions: allowedReactions)
            |> deliverOnMainQueue).start(error: { [weak self] error in
                guard let self, let component = self.component else {
                    return
                }
                self.isApplyingSettings = false
                self.state?.updated(transition: .immediate)
                
                switch error {
                case .boostRequired:
                    self.displayPremiumScreen()
                case .generic:
                    let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                    //TODO:localize
                    self.environment?.controller()?.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: presentationData), title: nil, text: "An error occurred", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                }
            }, completed: { [weak self] in
                guard let self else {
                    return
                }
                self.appliedAllowedReactions = allowedReactions
                self.environment?.controller()?.dismiss()
            })
        }
        
        private func displayPremiumScreen() {
            guard let component = self.component else {
                return
            }
            
            let _ = (component.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: component.peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let component = self.component, let peer, let status = self.boostStatus else {
                    return
                }
                
                let premiumConfiguration = PremiumConfiguration.with(appConfiguration: component.context.currentAppConfiguration.with { $0 })
                
                let link = status.url
                let controller = PremiumLimitScreen(context: component.context, subject: .storiesChannelBoost(peer: peer, boostSubject: .channelReactions, isCurrent: true, level: Int32(status.level), currentLevelBoosts: Int32(status.currentLevelBoosts), nextLevelBoosts: status.nextLevelBoosts.flatMap(Int32.init), link: link, myBoostCount: 0, canBoostAgain: false), count: Int32(status.boosts), action: { [weak self] in
                    guard let self, let component = self.component else {
                        return true
                    }
                            
                    UIPasteboard.general.string = link
                    let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                    self.environment?.controller()?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.ChannelBoost_BoostLinkCopied), elevatedLayout: false, position: .bottom, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                    return true
                }, openStats: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.openBoostStats()
                }, openGift: premiumConfiguration.giveawayGiftsPurchaseAvailable ? { [weak self] in
                    guard let self, let component = self.component else {
                        return
                    }
                    let controller = createGiveawayController(context: component.context, peerId: component.peerId, subject: .generic)
                    self.environment?.controller()?.push(controller)
                } : nil)
                self.environment?.controller()?.push(controller)
                
                HapticFeedback().impact(.light)
            })
        }
        
        private func openBoostStats() {
            guard let component = self.component else {
                return
            }
            
            let _ = (component.context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.StatsDatacenterId(id: component.peerId)
            )
            |> deliverOnMainQueue).start(next: { [weak self] statsDatacenterId in
                guard let self, let component = self.component, let boostStatus = self.boostStatus else {
                    return
                }
                guard let statsDatacenterId else {
                    return
                }
                
                let statsController = component.context.sharedContext.makeChannelStatsController(context: component.context, updatedPresentationData: nil, peerId: component.peerId, boosts: true, boostStatus: boostStatus, statsDatacenterId: statsDatacenterId)
                self.environment?.controller()?.push(statsController)
            })
        }
        
        func update(component: PeerAllowedReactionsScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: Transition) -> CGSize {
            self.isUpdating = true
            defer {
                self.isUpdating = false
            }
            
            
            let environment = environment[EnvironmentType.self].value
            let themeUpdated = self.environment?.theme !== environment.theme
            self.environment = environment
            
            self.component = component
            self.state = state
            
            let topInset: CGFloat = 24.0
            let bottomInset: CGFloat = 8.0
            let sideInset: CGFloat = 16.0 + environment.safeInsets.left
            let textSideInset: CGFloat = 16.0
            
            let enabledReactions: [EmojiComponentReactionItem]
            if let current = self.enabledReactions {
                enabledReactions = current
            } else {
                enabledReactions = component.initialContent.enabledReactions
                self.enabledReactions = enabledReactions
                self.availableReactions = component.initialContent.availableReactions
                self.isEnabled = component.initialContent.isEnabled
                self.appliedAllowedReactions = component.initialContent.allowedReactions
            }
            var caretPosition = self.caretPosition ?? enabledReactions.count
            caretPosition = max(0, min(enabledReactions.count, caretPosition))
            self.caretPosition = caretPosition
            
            if self.emojiContentDisposable == nil {
                let emojiContent = EmojiPagerContentComponent.emojiInputData(
                    context: component.context,
                    animationCache: component.context.animationCache,
                    animationRenderer: component.context.animationRenderer,
                    isStandalone: false,
                    subject: .reactionList,
                    hasTrending: false,
                    topReactionItems: [],
                    areUnicodeEmojiEnabled: false,
                    areCustomEmojiEnabled: true,
                    chatPeerId: nil,
                    selectedItems: Set(),
                    backgroundIconColor: nil,
                    hasSearch: false,
                    forceHasPremium: true
                )
                self.emojiContentDisposable = (emojiContent
                |> deliverOnMainQueue).start(next: { [weak self] emojiContent in
                    guard let self else {
                        return
                    }
                    self.emojiContent = emojiContent
                    
                    emojiContent.inputInteractionHolder.inputInteraction = EmojiPagerContentComponent.InputInteraction(
                        performItemAction: { [weak self] _, item, _, _, _, _ in
                            guard let self, var enabledReactions = self.enabledReactions else {
                                return
                            }
                            if self.isApplyingSettings {
                                return
                            }
                            guard let itemFile = item.itemFile else {
                                return
                            }
                            
                            if let index = enabledReactions.firstIndex(where: { $0.file.fileId.id == itemFile.fileId.id }) {
                                enabledReactions.remove(at: index)
                                if let caretPosition = self.caretPosition, caretPosition > index {
                                    self.caretPosition = max(0, caretPosition - 1)
                                }
                            } else {
                                let reaction: MessageReaction.Reaction
                                if let availableReactions = self.availableReactions, let reactionItem = availableReactions.reactions.first(where: { $0.selectAnimation.fileId.id == itemFile.fileId.id }) {
                                    reaction = reactionItem.value
                                } else {
                                    reaction = .custom(itemFile.fileId.id)
                                    
                                    if let boostStatus = self.boostStatus {
                                        let enabledCustomReactions = enabledReactions.filter({ item in
                                            switch item.reaction {
                                            case .custom:
                                                return true
                                            case .builtin:
                                                return false
                                            }
                                        })
                                        
                                        let nextCustomReactionCount = enabledCustomReactions.count + 1
                                        if nextCustomReactionCount > boostStatus.level {
                                            //TODO:localize
                                            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                                            
                                            var animateAsReplacement = false
                                            if let currentUndoController = self.currentUndoController {
                                                currentUndoController.dismiss()
                                                animateAsReplacement = true
                                            }
                                            
                                            let undoController = UndoOverlayController(presentationData: presentationData, content: .sticker(context: component.context, file: itemFile, loop: false, title: nil, text: "Your channel needs to reach **Level \(nextCustomReactionCount)** to add **\(nextCustomReactionCount) custom emoji as reactions.**", undoText: nil, customAction: nil), elevatedLayout: false, position: .bottom, animateInAsReplacement: animateAsReplacement, action: { _ in return false })
                                            self.currentUndoController = undoController
                                            self.environment?.controller()?.present(undoController, in: .current)
                                        }
                                    }
                                }
                                let item = EmojiComponentReactionItem(reaction: reaction, file: itemFile)
                                
                                if let caretPosition = self.caretPosition, caretPosition < enabledReactions.count {
                                    enabledReactions.insert(item, at: caretPosition)
                                    self.caretPosition = caretPosition + 1
                                } else {
                                    enabledReactions.append(item)
                                    self.caretPosition = enabledReactions.count
                                }
                            }
                            self.enabledReactions = enabledReactions
                            if !self.isUpdating {
                                self.state?.updated(transition: .spring(duration: 0.25))
                            }
                        },
                        deleteBackwards: {
                        },
                        openStickerSettings: {
                        },
                        openFeatured: {
                        },
                        openSearch: {
                        },
                        addGroupAction: { _, _, _ in
                        },
                        clearGroup: { _ in
                        },
                        pushController: { c in
                        },
                        presentController: { c in
                        },
                        presentGlobalOverlayController: { c in
                        },
                        navigationController: {
                            return nil
                        },
                        requestUpdate: { _ in
                        },
                        updateSearchQuery: { _ in
                        },
                        updateScrollingToItemGroup: {
                        },
                        onScroll: {},
                        chatPeerId: nil,
                        peekBehavior: nil,
                        customLayout: nil,
                        externalBackground: nil,
                        externalExpansionView: nil,
                        customContentView: nil,
                        useOpaqueTheme: true,
                        hideBackground: false,
                        stateContext: nil,
                        addImage: nil
                    )
                    
                    if !self.isUpdating {
                        self.state?.updated(transition: .immediate)
                    }
                })
            }
            
            if self.boostStatusDisposable == nil {
                self.boostStatusDisposable = (component.context.engine.peers.getChannelBoostStatus(peerId: component.peerId)
                |> deliverOnMainQueue).start(next: { [weak self] boostStatus in
                    guard let self else {
                        return
                    }
                    self.boostStatus = boostStatus
                    if !self.isUpdating {
                        self.state?.updated(transition: .immediate)
                    }
                })
            }
            
            if themeUpdated {
                self.backgroundColor = environment.theme.list.blocksBackgroundColor
            }
            
            var contentHeight: CGFloat = 0.0
            contentHeight += environment.navigationHeight
            contentHeight += topInset
            
            let switchSize = self.switchItem.update(
                transition: transition,
                component: AnyComponent(ListSwitchItemComponent(
                    theme: environment.theme,
                    title: environment.strings.PeerInfo_AllowedReactions_AllowAllText,
                    value: self.isEnabled,
                    valueUpdated: { [weak self] value in
                        guard let self else {
                            return
                        }
                        if self.isEnabled != value {
                            self.isEnabled = value
                            
                            if self.isEnabled {
                                if var enabledReactions = self.enabledReactions, enabledReactions.isEmpty {
                                    if let availableReactions = self.availableReactions {
                                        for reactionItem in availableReactions.reactions {
                                            enabledReactions.append(EmojiComponentReactionItem(reaction: reactionItem.value, file: reactionItem.selectAnimation))
                                        }
                                    }
                                    self.enabledReactions = enabledReactions
                                    self.caretPosition = enabledReactions.count
                                }
                            } else {
                                self.displayInput = false
                            }
                            
                            self.state?.updated(transition: .easeInOut(duration: 0.25))
                        }
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: .greatestFiniteMagnitude)
            )
            let switchFrame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: switchSize)
            if let switchView = self.switchItem.view {
                if switchView.superview == nil {
                    self.scrollView.addSubview(switchView)
                }
                transition.setFrame(view: switchView, frame: switchFrame)
            }
            contentHeight += switchSize.height
            contentHeight += 7.0
            
            //TODO:localize
            let switchInfoTextSize = self.switchInfoText.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(
                        string: "You can add emoji from any emoji pack as a reaction.",
                        font: Font.regular(13.0),
                        textColor: environment.theme.list.freeTextColor
                    )),
                    maximumNumberOfLines: 0
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - textSideInset * 2.0, height: .greatestFiniteMagnitude)
            )
            let switchInfoTextFrame = CGRect(origin: CGPoint(x: sideInset + textSideInset, y: contentHeight), size: switchInfoTextSize)
            if let switchInfoTextView = self.switchInfoText.view {
                if switchInfoTextView.superview == nil {
                    switchInfoTextView.layer.anchorPoint = CGPoint()
                    self.scrollView.addSubview(switchInfoTextView)
                }
                transition.setPosition(view: switchInfoTextView, position: switchInfoTextFrame.origin)
                switchInfoTextView.bounds = CGRect(origin: CGPoint(), size: switchInfoTextFrame.size)
            }
            contentHeight += switchInfoTextSize.height
            contentHeight += 37.0
            
            if self.isEnabled {
                var animateIn = false
                
                let reactionsTitleText: ComponentView<Empty>
                if let current = self.reactionsTitleText {
                    reactionsTitleText = current
                } else {
                    reactionsTitleText = ComponentView()
                    self.reactionsTitleText = reactionsTitleText
                    animateIn = true
                }
                
                //TODO:localize
                let reactionsTitleTextSize = reactionsTitleText.update(
                    transition: .immediate,
                    component: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(
                            string: "AVAILABLE REACTIONS",
                            font: Font.regular(13.0),
                            textColor: environment.theme.list.freeTextColor
                        )),
                        maximumNumberOfLines: 0
                    )),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - textSideInset * 2.0, height: .greatestFiniteMagnitude)
                )
                let reactionsTitleTextFrame = CGRect(origin: CGPoint(x: sideInset + textSideInset, y: contentHeight), size: reactionsTitleTextSize)
                if let reactionsTitleTextView = reactionsTitleText.view {
                    if reactionsTitleTextView.superview == nil {
                        reactionsTitleTextView.layer.anchorPoint = CGPoint()
                        self.scrollView.addSubview(reactionsTitleTextView)
                    }
                    
                    if animateIn {
                        reactionsTitleTextView.frame = reactionsTitleTextFrame
                        if !transition.animation.isImmediate {
                            reactionsTitleTextView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        }
                    } else {
                        transition.setPosition(view: reactionsTitleTextView, position: reactionsTitleTextFrame.origin)
                        reactionsTitleTextView.bounds = CGRect(origin: CGPoint(), size: reactionsTitleTextFrame.size)
                    }
                }
                contentHeight += reactionsTitleTextSize.height
                contentHeight += 6.0
                
                let reactionInput: ComponentView<Empty>
                if let current = self.reactionInput {
                    reactionInput = current
                } else {
                    reactionInput = ComponentView()
                    self.reactionInput = reactionInput
                }
                
                //TOOD:localize
                let reactionInputSize = reactionInput.update(
                    transition: animateIn ? .immediate : transition,
                    component: AnyComponent(EmojiListInputComponent(
                        context: component.context,
                        theme: environment.theme,
                        placeholder: "Add Reactions...",
                        reactionItems: enabledReactions,
                        isInputActive: self.displayInput,
                        caretPosition: caretPosition,
                        activateInput: { [weak self] in
                            guard let self else {
                                return
                            }
                            if self.emojiContent != nil && !self.displayInput {
                                self.displayInput = true
                                self.state?.updated(transition: .spring(duration: 0.5))
                            }
                        },
                        setCaretPosition: { [weak self] value in
                            guard let self else {
                                return
                            }
                            if self.caretPosition != value {
                                self.caretPosition = value
                                self.state?.updated(transition: .immediate)
                            }
                        }
                    )),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: .greatestFiniteMagnitude)
                )
                let reactionInputFrame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: reactionInputSize)
                if let reactionInputView = reactionInput.view {
                    if reactionInputView.superview == nil {
                        self.scrollView.addSubview(reactionInputView)
                    }
                    if animateIn {
                        reactionInputView.frame = reactionInputFrame
                        if !transition.animation.isImmediate {
                            reactionInputView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        }
                    } else {
                        transition.setFrame(view: reactionInputView, frame: reactionInputFrame)
                    }
                }
                contentHeight += reactionInputSize.height
                contentHeight += 7.0
                
                let reactionsInfoText: ComponentView<Empty>
                if let current = self.reactionsInfoText {
                    reactionsInfoText = current
                } else {
                    reactionsInfoText = ComponentView()
                    self.reactionsInfoText = reactionsInfoText
                }
                
                //TODO:localize
                let body = MarkdownAttributeSet(font: UIFont.systemFont(ofSize: 13.0), textColor: environment.theme.list.freeTextColor)
                let link = MarkdownAttributeSet(font: UIFont.systemFont(ofSize: 13.0), textColor: environment.theme.list.itemAccentColor, additionalAttributes: ["URL": true as NSNumber])
                let attributes = MarkdownAttributes(body: body, bold: body, link: link, linkAttribute: { _ in
                    return nil
                })
                let reactionsInfoTextSize = reactionsInfoText.update(
                    transition: .immediate,
                    component: AnyComponent(MultilineTextComponent(
                        text: .markdown(text: "You can also [create your own]() emoji packs and use them.", attributes: attributes),
                        maximumNumberOfLines: 0
                    )),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width - sideInset * 2.0 - textSideInset * 2.0, height: .greatestFiniteMagnitude)
                )
                let reactionsInfoTextFrame = CGRect(origin: CGPoint(x: sideInset + textSideInset, y: contentHeight), size: reactionsInfoTextSize)
                if let reactionsInfoTextView = reactionsInfoText.view {
                    if reactionsInfoTextView.superview == nil {
                        reactionsInfoTextView.layer.anchorPoint = CGPoint()
                        self.scrollView.addSubview(reactionsInfoTextView)
                    }
                    if animateIn {
                        reactionsInfoTextView.frame = reactionsInfoTextFrame
                        if !transition.animation.isImmediate {
                            reactionsInfoTextView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        }
                    } else {
                        transition.setPosition(view: reactionsInfoTextView, position: reactionsInfoTextFrame.origin)
                        reactionsInfoTextView.bounds = CGRect(origin: CGPoint(), size: reactionsInfoTextFrame.size)
                    }
                }
                contentHeight += reactionsInfoTextSize.height
                contentHeight += 6.0
            } else {
                if let reactionsTitleText = self.reactionsTitleText {
                    self.reactionsTitleText = nil
                    if let reactionsTitleTextView = reactionsTitleText.view {
                        if !transition.animation.isImmediate {
                            reactionsTitleTextView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak reactionsTitleTextView] _ in
                                reactionsTitleTextView?.removeFromSuperview()
                            })
                        } else {
                            reactionsTitleTextView.removeFromSuperview()
                        }
                    }
                }
                
                if let reactionInput = self.reactionInput {
                    self.reactionInput = nil
                    if let reactionInputView = reactionInput.view {
                        if !transition.animation.isImmediate {
                            reactionInputView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak reactionInputView] _ in
                                reactionInputView?.removeFromSuperview()
                            })
                        } else {
                            reactionInputView.removeFromSuperview()
                        }
                    }
                }
                
                if let reactionsInfoText = self.reactionsInfoText {
                    self.reactionsInfoText = nil
                    if let reactionsInfoTextView = reactionsInfoText.view {
                        if !transition.animation.isImmediate {
                            reactionsInfoTextView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak reactionsInfoTextView] _ in
                                reactionsInfoTextView?.removeFromSuperview()
                            })
                        } else {
                            reactionsInfoTextView.removeFromSuperview()
                        }
                    }
                }
            }
            
            //TODO:localize
            var buttonContents: [AnyComponentWithIdentity<Empty>] = []
            buttonContents.append(AnyComponentWithIdentity(id: AnyHashable(0 as Int), component: AnyComponent(
                Text(text: "Update Reactions", font: Font.semibold(17.0), color: environment.theme.list.itemCheckColors.foregroundColor)
            )))
            
            let customReactionCount = self.isEnabled ? enabledReactions.filter({ item in
                switch item.reaction {
                case .custom:
                    return true
                case .builtin:
                    return false
                }
            }).count : 0
            
            if let boostStatus = self.boostStatus, customReactionCount > boostStatus.level {
                //TODO:localize
                buttonContents.append(AnyComponentWithIdentity(id: AnyHashable(1 as Int), component: AnyComponent(ButtonSubtitleComponent(
                    count: customReactionCount,
                    theme: environment.theme
                ))))
            }
            
            let buttonSize = self.actionButton.update(
                transition: transition,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        color: environment.theme.list.itemCheckColors.fillColor,
                        foreground: environment.theme.list.itemCheckColors.foregroundColor,
                        pressedColor: environment.theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.8)
                    ),
                    content: AnyComponentWithIdentity(id: AnyHashable(0 as Int), component: AnyComponent(
                        VStack(buttonContents, spacing: 3.0)
                    )),
                    isEnabled: true,
                    tintWhenDisabled: false,
                    displaysProgress: self.isApplyingSettings,
                    action: { [weak self] in
                        guard let self else {
                            return
                        }
                        self.applySettings()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: 50.0)
            )
            contentHeight += buttonSize.height
            
            var inputHeight: CGFloat = 0.0
            if self.displayInput, let emojiContent = self.emojiContent {
                let reactionSelectionControl: ComponentView<Empty>
                var animateIn = false
                if let current = self.reactionSelectionControl {
                    reactionSelectionControl = current
                } else {
                    animateIn = true
                    reactionSelectionControl = ComponentView()
                    self.reactionSelectionControl = reactionSelectionControl
                }
                let reactionSelectionControlSize = reactionSelectionControl.update(
                    transition: animateIn ? .immediate : transition,
                    component: AnyComponent(EmojiSelectionComponent(
                        theme: environment.theme,
                        strings: environment.strings,
                        sideInset: environment.safeInsets.left,
                        bottomInset: environment.safeInsets.bottom,
                        deviceMetrics: environment.deviceMetrics,
                        emojiContent: emojiContent.withSelectedItems(Set(enabledReactions.map(\.file.fileId))),
                        backgroundIconColor: nil,
                        backgroundColor: environment.theme.list.itemBlocksBackgroundColor,
                        separatorColor: environment.theme.list.itemBlocksSeparatorColor,
                        backspace: enabledReactions.isEmpty ? nil : { [weak self] in
                            guard let self, var enabledReactions = self.enabledReactions, !enabledReactions.isEmpty else {
                                return
                            }
                            if let caretPosition = self.caretPosition, caretPosition < enabledReactions.count {
                                if caretPosition > 0 {
                                    enabledReactions.remove(at: caretPosition - 1)
                                    self.caretPosition = caretPosition - 1
                                }
                            } else {
                                enabledReactions.removeLast()
                                self.caretPosition = enabledReactions.count
                            }
                            self.enabledReactions = enabledReactions
                            if !self.isUpdating {
                                self.state?.updated(transition: .spring(duration: 0.25))
                            }
                        }
                    )),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width, height: min(340.0, max(50.0, availableSize.height - 200.0)))
                )
                let reactionSelectionControlFrame = CGRect(origin: CGPoint(x: 0.0, y: availableSize.height - reactionSelectionControlSize.height), size: reactionSelectionControlSize)
                if let reactionSelectionControlView = reactionSelectionControl.view {
                    if reactionSelectionControlView.superview == nil {
                        self.addSubview(reactionSelectionControlView)
                    }
                    if animateIn {
                        reactionSelectionControlView.frame = reactionSelectionControlFrame
                        transition.animatePosition(view: reactionSelectionControlView, from: CGPoint(x: 0.0, y: reactionSelectionControlFrame.height), to: CGPoint(), additive: true)
                    } else {
                        transition.setFrame(view: reactionSelectionControlView, frame: reactionSelectionControlFrame)
                    }
                }
                inputHeight = reactionSelectionControlSize.height
            } else if let reactionSelectionControl = self.reactionSelectionControl {
                self.reactionSelectionControl = nil
                if let reactionSelectionControlView = reactionSelectionControl.view {
                    transition.setPosition(view: reactionSelectionControlView, position: CGPoint(x: reactionSelectionControlView.center.x, y: availableSize.height + reactionSelectionControlView.bounds.height * 0.5), completion: { [weak reactionSelectionControlView] _ in
                        reactionSelectionControlView?.removeFromSuperview()
                    })
                }
            }
            
            let buttonY: CGFloat
            
            if self.displayInput {
                contentHeight += bottomInset + 8.0
                contentHeight += inputHeight
                
                buttonY = availableSize.height - bottomInset - 8.0 - inputHeight - buttonSize.height
            } else {
                contentHeight += bottomInset
                contentHeight += environment.safeInsets.bottom
                
                buttonY = availableSize.height - bottomInset - environment.safeInsets.bottom - buttonSize.height
            }
            
            let buttonFrame = CGRect(origin: CGPoint(x: sideInset, y: buttonY), size: buttonSize)
            if let buttonView = self.actionButton.view {
                if buttonView.superview == nil {
                    self.addSubview(buttonView)
                }
                transition.setFrame(view: buttonView, frame: buttonFrame)
                transition.setAlpha(view: buttonView, alpha: self.isEnabled ? 1.0 : 0.0)
            }
            
            let contentSize = CGSize(width: availableSize.width, height: contentHeight)
            if self.scrollView.frame != CGRect(origin: CGPoint(), size: availableSize) {
                self.scrollView.frame = CGRect(origin: CGPoint(), size: availableSize)
            }
            if self.scrollView.contentSize != contentSize {
                self.scrollView.contentSize = contentSize
            }
            let scrollInsets = UIEdgeInsets(top: environment.navigationHeight, left: 0.0, bottom: environment.safeInsets.bottom, right: 0.0)
            if self.scrollView.scrollIndicatorInsets != scrollInsets {
                self.scrollView.scrollIndicatorInsets = scrollInsets
            }
            
            self.updateScrolling(transition: transition)
            
            return availableSize
        }
    }
    
    func makeView() -> View {
        return View()
    }
    
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: Transition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

public class PeerAllowedReactionsScreen: ViewControllerComponentContainer {
    public final class Content: Equatable {
        public let isEnabled: Bool
        public let enabledReactions: [EmojiComponentReactionItem]
        public let availableReactions: AvailableReactions?
        public let allowedReactions: PeerAllowedReactions?
        
        init(
            isEnabled: Bool,
            enabledReactions: [EmojiComponentReactionItem],
            availableReactions: AvailableReactions?,
            allowedReactions: PeerAllowedReactions?
        ) {
            self.isEnabled = isEnabled
            self.enabledReactions = enabledReactions
            self.availableReactions = availableReactions
            self.allowedReactions = allowedReactions
        }
        
        public static func ==(lhs: Content, rhs: Content) -> Bool {
            if lhs === rhs {
                return true
            }
            if lhs.isEnabled != rhs.isEnabled {
                return false
            }
            if lhs.enabledReactions != rhs.enabledReactions {
                return false
            }
            if lhs.availableReactions != rhs.availableReactions {
                return false
            }
            if lhs.allowedReactions != rhs.allowedReactions {
                return false
            }
            return true
        }
    }
    
    private let context: AccountContext
    private var isDismissed: Bool = false
    
    public init(
        context: AccountContext,
        peerId: EnginePeer.Id,
        initialContent: Content
    ) {
        self.context = context
        
        super.init(context: context, component: PeerAllowedReactionsScreenComponent(
            context: context,
            peerId: peerId,
            initialContent: initialContent
        ), navigationBarAppearance: .default, theme: .default)
        
        self.scrollToTop = { [weak self] in
            guard let self, let componentView = self.node.hostView.componentView as? PeerAllowedReactionsScreenComponent.View else {
                return
            }
            componentView.scrollToTop()
        }
        
        self.attemptNavigation = { [weak self] complete in
            guard let self, let componentView = self.node.hostView.componentView as? PeerAllowedReactionsScreenComponent.View else {
                return true
            }
            
            return componentView.attemptNavigation(complete: complete)
        }
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
    }
    
    @objc private func cancelPressed() {
        self.dismiss()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
    }
    
    public static func content(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Content, NoError> {
        return combineLatest(
            context.engine.stickers.availableReactions(),
            context.account.postbox.combinedView(keys: [.cachedPeerData(peerId: peerId)])
        )
        |> mapToSignal { availableReactions, combinedView -> Signal<Content, NoError> in
            guard let cachedDataView = combinedView.views[.cachedPeerData(peerId: peerId)] as? CachedPeerDataView, let cachedData = cachedDataView.cachedPeerData as? CachedChannelData else {
                return .complete()
            }
            
            var reactions: [MessageReaction.Reaction] = []
            var isEnabled = false
            
            let allowedReactions = cachedData.allowedReactions.knownValue
            if let allowedReactions {
                switch allowedReactions {
                case .all:
                    isEnabled = true
                    if let availableReactions {
                        reactions = availableReactions.reactions.map(\.value)
                    }
                case let .limited(list):
                    isEnabled = true
                    reactions.append(contentsOf: list)
                case .empty:
                    isEnabled = false
                }
            }
            
            var missingReactionFiles: [Int64] = []
            for reaction in reactions {
                if let availableReactions, let _ = availableReactions.reactions.first(where: { $0.value == reaction }) {
                } else {
                    if case let .custom(fileId) = reaction {
                        if !missingReactionFiles.contains(fileId) {
                            missingReactionFiles.append(fileId)
                        }
                    }
                }
            }
            
            return context.engine.stickers.resolveInlineStickers(fileIds: missingReactionFiles)
            |> map { files -> Content in
                var result: [EmojiComponentReactionItem] = []
                
                for reaction in reactions {
                    if let availableReactions, let item = availableReactions.reactions.first(where: { $0.value == reaction }) {
                        result.append(EmojiComponentReactionItem(reaction: reaction, file: item.selectAnimation))
                    } else {
                        if case let .custom(fileId) = reaction {
                            if let file = files[fileId] {
                                result.append(EmojiComponentReactionItem(reaction: reaction, file: file))
                            }
                        }
                    }
                }
                
                return Content(isEnabled: isEnabled, enabledReactions: result, availableReactions: availableReactions, allowedReactions: allowedReactions)
            }
        }
        |> distinctUntilChanged
    }
}