//
//  AppDelegateAlertExtensions.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 13.10.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import Foundation
import NotificationBannerSwift
import OSLog
import UIKit

extension AppDelegate {
  static var mainSceneDelegate: SceneDelegate? {
    UIApplication.shared.connectedScenes
      // only scenes that are attached
      .filter { $0.activationState.rawValue >= 0 }
      // sort order: foregroundActive < foregroundInactive < background
      // this places the active tab first
      .sorted { $0.activationState.rawValue < $1.activationState.rawValue }
      // only "main" scene delegates
      .compactMap { $0.delegate as? SceneDelegate }.first
  }

  public func closeAllButActiveMainTabs() {
    var allMainScenes = UIApplication.shared.connectedScenes
      // only scenes that are attached
      .filter { $0.activationState.rawValue >= 0 }
      // sort order: foregroundActive < foregroundInactive < background
      // this places the active tab first
      .sorted { $0.activationState.rawValue < $1.activationState.rawValue }
      // only "main" scene delegates
      .filter { $0.delegate is SceneDelegate }
    if !allMainScenes.isEmpty {
      allMainScenes.removeFirst()
    }
    for scene in allMainScenes {
      terminateScene(scene)
    }
  }

  private func terminateScene(_ scene: UIScene) {
    UIApplication.shared.requestSceneSessionDestruction(
      scene.session,
      options: nil,
      errorHandler: { error in
        os_log(
          "AppDelegate: terminateScene failed: %s",
          log: self.log,
          type: .info,
          error.localizedDescription
        )
      }
    )
  }

  static var window: UIWindow? {
    mainSceneDelegate?.window
  }

  static func rootViewController() -> UIViewController? {
    Self.window?.rootViewController
  }

  static func topViewController(
    base: UIViewController? =
      window?.rootViewController
  )
    -> UIViewController? {
    if base?.presentedViewController is UIAlertController {
      return base
    }
    if let nav = base as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = base as? TabBarVC {
      return tab
    }
    if let splitVC = base as? SplitVC {
      return splitVC
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }

  static var mainWindowHostVC: MainSceneHostingViewController? {
    guard let topView = Self.topViewController(),
          (UIApplication.shared.delegate as! AppDelegate).storage.settings.app.isLibrarySynced
    else { return nil }
    return AppStoryboard.Main.checkForMainWindow(vc: topView)
  }
}

// MARK: - AppDelegate + AlertDisplayable

extension AppDelegate: AlertDisplayable {
  func display(
    title: String,
    subtitle: String,
    style: LogEntryType,
    notificationBanner popupVC: UIViewController
  ) {
    guard NotificationBannerQueue.default.numberOfBanners < 1,
          let topView = Self.topViewController(),
          topView.presentedViewController == nil,
          let _ = UIApplication.shared.mainWindow
    else { return }

    let banner = FloatingNotificationBanner(
      title: title,
      subtitle: subtitle,
      titleFont: .systemFont(ofSize: 15, weight: .semibold),
      titleColor: .white,
      subtitleFont: .systemFont(ofSize: 13),
      subtitleColor: .white,
      style: BannerStyle.from(logType: style),
      colors: AmperfyBannerColors()
    )
    banner.transparency = 1

    banner.onTap = {
      guard let topView = Self.topViewController(),
            topView.presentedViewController == nil
      else { return }
      topView.present(popupVC, animated: true, completion: nil)
    }

    // Pin a compact toast to the top-right on Mac / iPad; phones stay near full width.
    // Measure the text at that width. The banner otherwise sizes itself for the full window,
    // and the message draws outside the colored fill.
    let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    let horizontalPadding: CGFloat = 16
    let hostWidth = topView.view.bounds.width > 1
      ? topView.view.bounds.width
      : (UIApplication.shared.mainWindow?.bounds.width ?? 800)
    let preferredWidth = isPhone ? hostWidth - (horizontalPadding * 2) : 440
    let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    let subtitleFont = UIFont.systemFont(ofSize: 13)
    banner.bannerHeight = fittedBannerHeight(
      title: title,
      subtitle: subtitle,
      titleFont: titleFont,
      subtitleFont: subtitleFont,
      width: preferredWidth
    )
    let leftInset = max(horizontalPadding, hostWidth - preferredWidth - horizontalPadding)
    let topViewInset = UIEdgeInsets(
      top: isPhone ? 40 : 16,
      left: leftInset,
      bottom: 16,
      right: horizontalPadding
    )
    banner.show(
      queuePosition: QueuePosition.back,
      bannerPosition: BannerPosition.top,
      on: topView,
      edgeInsets: topViewInset,
      cornerRadius: 16,
      shadowOpacity: 0.5,
      shadowBlurRadius: 5
    )
  }

  private func fittedBannerHeight(
    title: String,
    subtitle: String,
    titleFont: UIFont,
    subtitleFont: UIFont,
    width: CGFloat
  ) -> CGFloat {
    let textWidth = max(160, width - 40)
    func measured(_ text: String, font: UIFont) -> CGFloat {
      guard !text.isEmpty else { return 0 }
      let rect = (text as NSString).boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      return ceil(rect.height)
    }
    let titleHeight = measured(title, font: titleFont)
    let subtitleHeight = measured(subtitle, font: subtitleFont)
    var textBlock = titleHeight + subtitleHeight
    if titleHeight > 0, subtitleHeight > 0 {
      textBlock += 8
    }
    // The banner keeps a clear spacer inside its frame (the status bar height on
    // Mac), so the colored pill is shorter than the frame. Add that back, plus
    // enough padding that both lines sit inside the fill.
    let spacerInsideFrame = UIDevice.current.userInterfaceIdiom == .phone
      ? 0
      : UIApplication.shared.statusBarFrame.height
    let contentHeight = max(textBlock + 48, 104)
    return contentHeight + spacerInsideFrame
  }

  func display(popup popupVC: UIViewController) {
    guard let topView = Self.topViewController(),
          topView.presentedViewController == nil
    else { return }
    popupVC.modalPresentationStyle = .overCurrentContext
    popupVC.modalTransitionStyle = .crossDissolve
    topView.present(popupVC, animated: true, completion: nil)
  }

  func createPopupVC(
    topic: String,
    shortMessage: String,
    detailMessage: String,
    logType: LogEntryType
  )
    -> UIViewController {
    let popupVC = NotificationDetailVC()
    popupVC.display(title: topic, message: detailMessage, type: logType)
    return popupVC
  }
}
