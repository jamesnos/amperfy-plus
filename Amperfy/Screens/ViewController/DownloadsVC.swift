//
//  DownloadsVC.swift
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
import Foundation
import UIKit

class DownloadsVC: SingleFetchedResultsTableViewController<DownloadMO> {
  override var sceneTitle: String? { "Downloads" }

  private var fetchedResultsController: DownloadsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var downloadManager: DownloadManageable!
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var isRestoringLocalCache = false

  init(account: Account) {
    super.init(style: .plain, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.downloads)
    downloadManager = appDelegate.getMeta(account.info).playableDownloadManager

    fetchedResultsController = DownloadsFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = createActionButtonMenu()
    navigationItem.rightBarButtonItem = optionsButton

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  private func createActionButtonMenu() -> UIMenu {
    let clearFinishedDownloadsAction = UIAction(
      title: "Clear finished downloads",
      image: UIImage.clear,
      handler: { _ in
        self.downloadManager.clearFinishedDownloads()
      }
    )
    let retryFailedDownloadsAction = UIAction(
      title: "Retry failed downloads",
      image: UIImage.redo,
      handler: { _ in
        self.downloadManager.resetFailedDownloads()
      }
    )
    let cancelAllDownloadsAction = UIAction(
      title: "Cancel all downloads",
      image: UIImage.cancleDownloads,
      handler: { _ in
        self.downloadManager.cancelDownloads()
      }
    )
    let deleteAllCacheAction = UIAction(
      title: "Delete All",
      image: UIImage.trash,
      attributes: .destructive,
      handler: { _ in
        self.confirmDeleteAllCache()
      }
    )
    return UIMenu(children: [
      clearFinishedDownloadsAction,
      retryFailedDownloadsAction,
      cancelAllDownloadsAction,
      deleteAllCacheAction,
    ])
  }

  private func confirmDeleteAllCache() {
    let alert = UIAlertController(
      title: "Delete All",
      message: "Are you sure you want to delete all downloaded songs and podcast episodes from the cache?",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
      self.deleteAllCache()
    }))
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(alert, animated: true)
  }

  private func deleteAllCache() {
    appDelegate.player.stop()
    downloadManager.stop()
    downloadManager.cancelDownloads()
    appDelegate.storage.main.library.deletePlayableCachePaths(for: account)
    appDelegate.storage.main.library.saveContext()
    CacheFileManager.shared.deletePlayableCache(accountInfo: account.info)
    downloadManager.clearFinishedDownloads()
    downloadManager.start()
    fetchedResultsController.fetch()
    tableView.reloadData()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    restoreLocalCacheIfNeeded()
  }

  private func restoreLocalCacheIfNeeded() {
    guard !isRestoringLocalCache else { return }
    isRestoringLocalCache = true
    spinner.startAnimating()
    tableView.isUserInteractionEnabled = false
    let accountObjectId = account.managedObject.objectID
    Task { @MainActor in
      defer {
        self.isRestoringLocalCache = false
        self.spinner.stopAnimating()
        self.tableView.isUserInteractionEnabled = true
      }
      do {
        try await self.appDelegate.storage.async.perform { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          asyncCompanion.library.reattachLocalPlayableCache(for: accountAsync)
        }
      } catch {
        self.appDelegate.eventLogger.report(topic: "Restore Local Cache", error: error)
      }
      self.fetchedResultsController.fetch()
      self.tableView.reloadData()
    }
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    let downdload = fetchedResultsController.getWrappedEntity(at: indexPath)
    guard let playable = downdload.element as? AbstractPlayable else { return nil }
    return PlayContext(containable: playable)
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    let download = fetchedResultsController.getWrappedEntity(at: indexPath)
    if let playable = download.element as? AbstractPlayable {
      cell.display(
        playable: playable,
        playContextCb: convertCellViewToPlayContext,
        rootView: self,
        download: download
      )
    }
    return cell
  }
}
