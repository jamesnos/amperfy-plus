//
//  TabBarVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import UIKit

// MARK: - TabBarVC

class TabBarVC: UITabBarController {
  @available(iOS 18.0, *)
  private var libraryGroup: UITabGroup? {
    get { _libraryGroup as? UITabGroup }
    set { _libraryGroup = newValue }
  }

  @available(iOS 18.0, *)
  private var searchTab: UISearchTab? {
    get { _searchTab as? UISearchTab }
    set { _searchTab = newValue }
  }

  @available(iOS 18.0, *)
  private var homeTab: UITab? {
    get { _homeTab as? UITab }
    set { _homeTab = newValue }
  }

  /// Type-erased storage so the class can compile against iOS 16.
  private var _libraryGroup: AnyObject?
  private var _searchTab: AnyObject?
  private var _homeTab: AnyObject?

  private var classicSearchNav: UINavigationController?
  private var classicHomeNav: UINavigationController?
  private var classicLibraryNav: UINavigationController?
  private var classicMiniPlayerBottomConstraint: NSLayoutConstraint?
  private var usesClassicTabs = false

  private let account: Account

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var welcomePopupPresenter = WelcomePopupPresenter()
  var miniPlayer: MiniPlayerView?

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self

    if #available(iOS 18.0, *) {
      setupModernTabs()
    } else {
      setupClassicTabs()
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryItemsChanged(notification:)),
      name: .LibraryItemsChanged,
      object: nil
    )

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    miniPlayer!.glassContainer.translatesAutoresizingMaskIntoConstraints = false

    if #available(iOS 26.0, *) {
      #if !targetEnvironment(macCatalyst)
        tabBarMinimizeBehavior = .onScrollDown
      #endif
      let accessory = UITabAccessory(contentView: miniPlayer!.glassContainer)
      bottomAccessory = accessory
    } else {
      installClassicMiniPlayer()
    }

    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    heightConstraint?.isActive = true
    if miniPlayer!.glassContainer.superview != nil {
      compactWidthConstraint = miniPlayer!.glassContainer.widthAnchor
        .constraint(equalTo: miniPlayer!.glassContainer.superview!.widthAnchor)
    }

    miniPlayer!.tabAccessoryTraitChangeCB = configureTraitChangesForMiniPlayer
    configureTraitChangesForMiniPlayer()
    registerMiniPlayerTraitObservers()

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder", message: "Offline Mode is active.")
    }
  }

  @available(iOS 18.0, *)
  private func setupModernTabs() {
    var fixTabs = [UITab]()

    let search = UISearchTab { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.search
          .getController(account: self.account)
      )
    }
    if #available(iOS 26.0, *) {
      search.automaticallyActivatesSearch = true
    }
    searchTab = search
    fixTabs.append(search)

    let home = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.icon,
      identifier: "Tabs.\(TabNavigatorItem.home.title)"
    ) { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
    }
    homeTab = home
    fixTabs.append(home)

    let librarySettings = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings
    let libraryTabs = librarySettings.order
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.image,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        tab.isHiddenByDefault = !librarySettings.isVisible(libraryType: item)
        return tab
      }

    let group = UITabGroup(
      title: "Library",
      image: .musicLibrary,
      identifier: "Tabs.Library",
      children: libraryTabs
    ) { tab in
      AppStoryboard.Main.segueToLibrary(account: self.account)
    }
    group.managingNavigationController = UINavigationController()
    group.allowsReordering = true
    libraryGroup = group
    fixTabs.append(group)

    tabs = fixTabs
  }

  private func setupClassicTabs() {
    usesClassicTabs = true

    let searchRoot = TabNavigatorItem.search.getController(account: account)
    let searchNav = UINavigationController(rootViewController: searchRoot)
    searchNav.tabBarItem = UITabBarItem(
      title: TabNavigatorItem.search.title,
      image: TabNavigatorItem.search.icon,
      selectedImage: nil
    )
    classicSearchNav = searchNav

    let homeRoot = TabNavigatorItem.home.getController(account: account)
    let homeNav = UINavigationController(rootViewController: homeRoot)
    homeNav.tabBarItem = UITabBarItem(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.icon,
      selectedImage: nil
    )
    classicHomeNav = homeNav

    let libraryRoot = AppStoryboard.Main.segueToLibrary(account: account)
    let libraryNav = UINavigationController(rootViewController: libraryRoot)
    libraryNav.tabBarItem = UITabBarItem(
      title: "Library",
      image: .musicLibrary,
      selectedImage: nil
    )
    classicLibraryNav = libraryNav

    viewControllers = [searchNav, homeNav, libraryNav]
  }

  private func installClassicMiniPlayer() {
    guard let miniPlayer else { return }
    let container = miniPlayer.glassContainer
    view.addSubview(container)
    container.translatesAutoresizingMaskIntoConstraints = false

    let bottom = container.bottomAnchor.constraint(
      equalTo: tabBar.topAnchor,
      constant: -8
    )
    classicMiniPlayerBottomConstraint = bottom
    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      container.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -12
      ),
      bottom,
    ])
    applyClassicMiniPlayerInsets()
  }

  private func applyClassicMiniPlayerInsets() {
    let height = heightConstraint?.constant ?? 48
    additionalSafeAreaInsets.bottom = height + 16
  }

  private func registerMiniPlayerTraitObservers() {
    if #available(iOS 17.0, *) {
      registerForTraitChanges(
        [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
        handler: { (self: Self, previousTraitCollection: UITraitCollection) in
          self.miniPlayer?
            .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
          self.configureTraitChangesForMiniPlayer()
        }
      )
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if #unavailable(iOS 17.0) {
      if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass ||
        previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
        miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: traitCollection.horizontalSizeClass)
        configureTraitChangesForMiniPlayer()
      }
    }
  }

  private func mainContent() -> UIView {
    if traitCollection.horizontalSizeClass == .regular, let selectedViewController {
      return selectedViewController.view
    }
    return view
  }

  var centerConstraint: NSLayoutConstraint?
  var regularWidthConstraint: NSLayoutConstraint?
  var heightConstraint: NSLayoutConstraint?
  var compactWidthConstraint: NSLayoutConstraint?

  func configureTraitChangesForMiniPlayer() {
    guard let miniPlayer else { return }

    if #available(iOS 26.0, *) {
      let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline
      applyMiniPlayerLayout(isInline: isInline)
    } else {
      applyMiniPlayerLayout(isInline: false)
      applyClassicMiniPlayerInsets()
    }
  }

  private func applyMiniPlayerLayout(isInline: Bool) {
    guard let miniPlayer else { return }

    if traitCollection.horizontalSizeClass == .regular {
      centerConstraint = miniPlayer.glassContainer.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      let mainContentView = mainContent()
      var playerWidth = mainContentView.frame.width - mainContentView.safeAreaInsets
        .left - mainContentView.safeAreaInsets.right
      playerWidth = min(playerWidth, 600)
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      if #available(iOS 26.0, *) {
        regularWidthConstraint = miniPlayer.glassContainer.widthAnchor
          .constraint(equalToConstant: playerWidth)
        regularWidthConstraint?.isActive = true
        centerConstraint?.isActive = true
      }
      heightConstraint?.constant = 60.0
    } else if isInline {
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    } else {
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = compactWidthConstraint?.firstItem != nil
    }

    miniPlayer.glassContainer.setNeedsLayout()
    miniPlayer.glassContainer.layoutIfNeeded()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    configureTraitChangesForMiniPlayer()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    refresh()
    if #available(iOS 18.0, *), !usesClassicTabs {
      selectedTab = homeTab
    } else {
      selectedViewController = classicHomeNav
    }
    welcomePopupPresenter.displayInfoPopupsIfNeeded()
  }

  @objc
  func handleLibraryItemsChanged(notification: Notification) {
    refresh()
  }

  func refresh() {
    if #available(iOS 18.0, *), let libraryGroup, !usesClassicTabs {
      let config = appDelegate.storage.settings.accounts.getSetting(account.info).read
        .libraryDisplaySettings
      libraryGroup.displayOrderIdentifiers = config.order.compactMap { "Tabs.\($0.displayName)" }
      for tab in libraryGroup.displayOrder {
        guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
        if let _ = config.inUse.first(where: { $0 == item }) {
          tab.isHidden = false
        } else {
          tab.isHidden = true
        }
      }
    }
  }

  public func push(vc: UIViewController) {
    if #available(iOS 18.0, *), let libraryGroup, !usesClassicTabs {
      if selectedTab?.managingTabGroup !== libraryGroup, selectedTab !== libraryGroup {
        selectedTab = libraryGroup
      }
      libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
      return
    }
    selectedViewController = classicLibraryNav
    classicLibraryNav?.pushViewController(vc, animated: true)
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  @available(iOS 18.0, *)
  func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
    var order = [LibraryDisplayType]()
    var visibleItems = Set<LibraryDisplayType>()
    guard let libraryGroup else { return }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      order.append(item)
      if !tab.isHidden {
        visibleItems.insert(item)
      }
    }
    appDelegate.storage.settings.accounts
      .updateSetting(account.info) { accountSettings in
        accountSettings.libraryDisplaySettings = LibraryDisplaySettings(
          order: order,
          inUse: visibleItems
        )
      }
    NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil, userInfo: nil)
  }
}

// MARK: MainSceneHostingViewController

extension TabBarVC: MainSceneHostingViewController {
  public func pushNavLibrary(vc: UIViewController) {
    push(vc: vc)
  }

  public func pushLibraryCategory(vc: UIViewController) {
    if #available(iOS 18.0, *), let libraryGroup, !usesClassicTabs {
      libraryGroup.managingNavigationController?.popToRootViewController(animated: false)
      push(vc: vc)
      return
    }
    classicLibraryNav?.popToRootViewController(animated: false)
    push(vc: vc)
  }

  func pushTabCategory(tabCategory: TabNavigatorItem) {
    switch tabCategory {
    case .home:
      if #available(iOS 18.0, *), !usesClassicTabs {
        selectedTab = homeTab
      } else {
        selectedViewController = classicHomeNav
      }
    case .search:
      if #available(iOS 18.0, *), !usesClassicTabs {
        selectedTab = searchTab
      } else {
        selectedViewController = classicSearchNav
      }
    case .playlistGenerator:
      push(vc: tabCategory.getController(account: account))
    }
    configureTraitChangesForMiniPlayer()
  }

  func displaySearch() {
    visualizePopupPlayer(direction: .close, animated: true) {
      if #available(iOS 18.0, *), let searchTab = self.searchTab, !self.usesClassicTabs {
        self.selectedTab = searchTab
        searchTab.viewController?.navigationController?.popToRootViewController(animated: false)
        Task {
          try await Task.sleep(nanoseconds: 500_000_000)
          if let searchTabVC = searchTab.viewController?.navigationController?
            .topViewController as? SearchVC {
            searchTabVC.activateSearchBar()
          }
        }
      } else {
        self.selectedViewController = self.classicSearchNav
        self.classicSearchNav?.popToRootViewController(animated: false)
        Task {
          try await Task.sleep(nanoseconds: 500_000_000)
          if let searchTabVC = self.classicSearchNav?.topViewController as? SearchVC {
            searchTabVC.activateSearchBar()
          }
        }
      }
    }
  }

  func getSafeAreaExtension() -> CGFloat {
    if #available(iOS 26.0, *) {
      return 0.0
    }
    return (heightConstraint?.constant ?? 48) + 16
  }
}
