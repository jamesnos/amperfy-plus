//
//  SearchVC.swift
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
import CoreData
import UIKit

// MARK: - SearchSection

public enum SearchSection: Int, CaseIterable {
  case History
  case Artist
  case Album
  case Playlist
  case Featured
  case Song
}

// MARK: - SearchDiffableDataSource

class SearchDiffableDataSource: BasicUITableViewDiffableDataSource {
  public var searchVC: SearchVC!

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch SearchSection(rawValue: section) {
    case .History:
      if searchVC.searchHistory.isEmpty {
        return ""
      } else {
        return "Recently Searched"
      }
    case .Playlist:
      return "Playlists"
    case .Artist:
      return "Artists"
    case .Album:
      return "Albums"
    case .Featured:
      return "Featured"
    case .Song:
      return "Songs"
    case .none:
      return ""
    }
  }
}

// MARK: - SearchVC

class SearchVC: BasicTableViewController {
  override var sceneTitle: String { "Search" }

  nonisolated private static let categoryPageSize = 10
  nonisolated private static let categoryResultCap = 100

  private var diffableDataSource: SearchDiffableDataSource?
  fileprivate var searchHistory: [SearchHistoryItem] = []
  fileprivate var artists: [Artist] = []
  fileprivate var albums: [Album] = []
  fileprivate var playlists: [Playlist] = []
  fileprivate var featuredSongs: [Song] = []
  fileprivate var songs: [Song] = []

  private var allArtistsIDs: [NSManagedObjectID] = []
  private var allAlbumsIDs: [NSManagedObjectID] = []
  private var allPlaylistsIDs: [NSManagedObjectID] = []
  private var allFeaturedSongsIDs: [NSManagedObjectID] = []
  private var allSongsIDs: [NSManagedObjectID] = []

  private var artistsVisibleCount = SearchVC.categoryPageSize
  private var albumsVisibleCount = SearchVC.categoryPageSize
  private var playlistsVisibleCount = SearchVC.categoryPageSize
  private var featuredVisibleCount = SearchVC.categoryPageSize
  private var songsVisibleCount = SearchVC.categoryPageSize

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private var isSearchActive = false
  /// Bumped on every search-text change so stale async results are ignored.
  private var searchGeneration = 0
  private var accountObjectId: NSManagedObjectID?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?

  init(account: Account) {
    self.account = account
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func createDiffableDataSource() -> SearchDiffableDataSource {
    let source =
      SearchDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        return self.tableView(self.tableView, cellForRowAt: indexPath)
      }
    source.searchVC = self
    return source
  }

  /// `reloadingSections`: sections whose header changed (applying a snapshot doesn't update the
  /// headers of unchanged sections)
  func updateDataSource(animated: Bool, reloadingSections: [SearchSection] = []) {
    guard let dataSource = tableView?.dataSource as? UITableViewDiffableDataSource<
      Int,
      NSManagedObjectID
    > else {
      assertionFailure("The data source has not implemented snapshot support while it should")
      return
    }
    var snapshot = dataSource.snapshot() as NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>
    snapshot.deleteAllItems()
    snapshot.appendSections(SearchSection.allCases.compactMap { $0.rawValue })
    snapshot.appendItems(
      searchHistory.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.History.rawValue
    )
    snapshot.appendItems(
      artists.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Artist.rawValue
    )
    snapshot.appendItems(
      albums.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Album.rawValue
    )
    snapshot.appendItems(
      playlists.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Playlist.rawValue
    )
    snapshot.appendItems(
      featuredSongs.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Featured.rawValue
    )
    snapshot.appendItems(
      songs.compactMap { $0.managedObject.objectID },
      toSection: SearchSection.Song.rawValue
    )
    snapshot.reloadSections(reloadingSections.map(\.rawValue))
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    /// Store the data source in an instance property to make sure it's retained.
    diffableDataSource = createDiffableDataSource()
    /// Assign the data source to your collection view.
    tableView.dataSource = diffableDataSource

    accountObjectId = account.managedObject.objectID
    searchHistory = appDelegate.storage.main.library.getSearchHistory(for: account)
    updateDataSource(animated: false)
    if #available(iOS 26.0, *) {
      navigationController?.navigationItem.searchBarPlacementAllowsExternalIntegration = true
    }

    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = CommonScreenOperations.tableSectionHeightLarge
    tableView.sectionHeaderTopPadding = 0.0

    containableAtIndexPathCallback = { indexPath in
      switch SearchSection(rawValue: indexPath.section) {
      case .History:
        return self.searchHistoryItem(at: indexPath.row)?.searchedPlayableContainable
      case .Playlist:
        return self.playlistAt(indexPath.row)
      case .Artist:
        return self.artistAt(indexPath.row)
      case .Album:
        return self.albumAt(indexPath.row)
      case .Featured:
        return self.featuredSongAt(indexPath.row)
      case .Song:
        return self.songAt(indexPath.row)
      case .none:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      switch SearchSection(rawValue: indexPath.section) {
      case .History:
        guard let container = self.searchHistoryItem(at: indexPath.row)?
          .searchedPlayableContainable else { return nil }
        return PlayContext(containable: container)
      case .Playlist:
        guard let entity = self.playlistAt(indexPath.row) else { return nil }
        return PlayContext(containable: entity)
      case .Artist:
        guard let entity = self.artistAt(indexPath.row) else { return nil }
        return PlayContext(containable: entity)
      case .Album:
        guard let entity = self.albumAt(indexPath.row) else { return nil }
        return PlayContext(containable: entity)
      case .Featured:
        guard let entity = self.featuredSongAt(indexPath.row) else { return nil }
        return PlayContext(containable: entity)
      case .Song:
        guard let entity = self.songAt(indexPath.row) else { return nil }
        return PlayContext(containable: entity)
      case .none:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      self.determSwipeActionContext(at: indexPath) { actionContext in
        completionHandler(actionContext)
      }
    }
    updateContentUnavailable()
    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem
      )
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Inline title avoids large-title + search-field collision on iPad.
    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.largeTitleDisplayMode = .never
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    appDelegate.userStatistics.visited(.search)
    configureSearchController(
      placeholder: "Search in \"Library\"",
      scopeButtonTitles: ["All", "Cached"]
    )
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.hidesSearchBarWhenScrolling = false
    navigationItem.preferredSearchBarPlacement = .stacked
    let searchText = searchController.searchBar.text ?? ""
    if searchText.isEmpty {
      reloadSearchHistory()
    }
  }

  private func reloadSearchHistory() {
    searchHistory = appDelegate.storage.main.library.getSearchHistory(for: account)
    isSearchActive = false
    clearRankedSearchResults()
    // Apply snapshot before any layout-triggering UIKit property changes.
    updateDataSource(animated: false, reloadingSections: [.History])
    tableView.separatorStyle = .singleLine
    updateContentUnavailable()
  }

  private func resetPaginationVisibleCounts() {
    artistsVisibleCount = Self.categoryPageSize
    albumsVisibleCount = Self.categoryPageSize
    playlistsVisibleCount = Self.categoryPageSize
    featuredVisibleCount = Self.categoryPageSize
    songsVisibleCount = Self.categoryPageSize
  }

  private func clearRankedSearchResults() {
    allArtistsIDs = []
    allAlbumsIDs = []
    allPlaylistsIDs = []
    allFeaturedSongsIDs = []
    allSongsIDs = []
    artists = []
    albums = []
    playlists = []
    featuredSongs = []
    songs = []
    resetPaginationVisibleCounts()
  }

  private func resolveDisplayedResults() {
    artists = allArtistsIDs
      .prefix(artistsVisibleCount)
      .compactMap { appDelegate.storage.main.context.object(with: $0) as? ArtistMO }
      .compactMap { Artist(managedObject: $0) }
    albums = allAlbumsIDs
      .prefix(albumsVisibleCount)
      .compactMap { appDelegate.storage.main.context.object(with: $0) as? AlbumMO }
      .compactMap { Album(managedObject: $0) }
    playlists = allPlaylistsIDs
      .prefix(playlistsVisibleCount)
      .compactMap { appDelegate.storage.main.context.object(with: $0) as? PlaylistMO }
      .compactMap { Playlist(library: appDelegate.storage.main.library, managedObject: $0) }
    featuredSongs = allFeaturedSongsIDs
      .prefix(featuredVisibleCount)
      .compactMap { appDelegate.storage.main.context.object(with: $0) as? SongMO }
      .compactMap { Song(managedObject: $0) }
    songs = allSongsIDs
      .prefix(songsVisibleCount)
      .compactMap { appDelegate.storage.main.context.object(with: $0) as? SongMO }
      .compactMap { Song(managedObject: $0) }
  }

  private func sectionHasMoreResults(_ section: SearchSection) -> Bool {
    switch section {
    case .Artist:
      return allArtistsIDs.count > artistsVisibleCount
    case .Album:
      return allAlbumsIDs.count > albumsVisibleCount
    case .Playlist:
      return allPlaylistsIDs.count > playlistsVisibleCount
    case .Featured:
      return allFeaturedSongsIDs.count > featuredVisibleCount
    case .Song:
      return allSongsIDs.count > songsVisibleCount
    case .History:
      return false
    }
  }

  private func showMoreResults(in section: SearchSection) {
    switch section {
    case .Artist:
      artistsVisibleCount = min(
        artistsVisibleCount + Self.categoryPageSize,
        allArtistsIDs.count
      )
    case .Album:
      albumsVisibleCount = min(
        albumsVisibleCount + Self.categoryPageSize,
        allAlbumsIDs.count
      )
    case .Playlist:
      playlistsVisibleCount = min(
        playlistsVisibleCount + Self.categoryPageSize,
        allPlaylistsIDs.count
      )
    case .Featured:
      featuredVisibleCount = min(
        featuredVisibleCount + Self.categoryPageSize,
        allFeaturedSongsIDs.count
      )
    case .Song:
      songsVisibleCount = min(
        songsVisibleCount + Self.categoryPageSize,
        allSongsIDs.count
      )
    case .History:
      return
    }
    resolveDisplayedResults()
    updateDataSource(animated: false, reloadingSections: [section])
  }

  public func activateSearchBar() {
    if isViewLoaded {
      // activate searchBar
      searchController.searchBar.becomeFirstResponder()
    }
  }

  private func clearSearchHistory() {
    appDelegate.storage.main.library.deleteSearchHistory()
    appDelegate.storage.main.library.saveContext()
    searchHistory = []
    // Non-animated: during animated deletes UITableView still asks for heights of
    // vanishing rows, which would hit searchHistory[index] out of range on iOS 16.
    updateDataSource(animated: false, reloadingSections: [.History])
    updateContentUnavailable()
  }

  private func searchHistoryItem(at index: Int) -> SearchHistoryItem? {
    searchHistory.indices.contains(index) ? searchHistory[index] : nil
  }

  private func playlistAt(_ index: Int) -> Playlist? {
    playlists.indices.contains(index) ? playlists[index] : nil
  }

  private func artistAt(_ index: Int) -> Artist? {
    artists.indices.contains(index) ? artists[index] : nil
  }

  private func albumAt(_ index: Int) -> Album? {
    albums.indices.contains(index) ? albums[index] : nil
  }

  private func featuredSongAt(_ index: Int) -> Song? {
    featuredSongs.indices.contains(index) ? featuredSongs[index] : nil
  }

  private func songAt(_ index: Int) -> Song? {
    songs.indices.contains(index) ? songs[index] : nil
  }

  func determSwipeActionContext(
    at indexPath: IndexPath,
    completionHandler: @escaping (_ actionContext: SwipeActionContext?) -> ()
  ) {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      guard let history = searchHistoryItem(at: indexPath.row),
            let container = history.searchedPlayableContainable
      else { completionHandler(nil); return }
      Task { @MainActor in
        do {
          try await container.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "History Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: container))
      }
    case .Playlist:
      guard let playlist = playlistAt(indexPath.row) else { completionHandler(nil); return }
      Task { @MainActor in
        do {
          try await playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: playlist))
      }
    case .Artist:
      guard let artist = artistAt(indexPath.row) else { completionHandler(nil); return }
      Task { @MainActor in
        do {
          try await artist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Artist Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: artist))
      }
    case .Album:
      guard let album = albumAt(indexPath.row) else { completionHandler(nil); return }
      Task { @MainActor in
        do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Album Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: album))
      }
    case .Featured:
      guard let song = featuredSongAt(indexPath.row) else { completionHandler(nil); return }
      completionHandler(SwipeActionContext(containable: song))
    case .Song:
      guard let song = songAt(indexPath.row) else { completionHandler(nil); return }
      completionHandler(SwipeActionContext(containable: song))
    case .none:
      completionHandler(nil)
    }
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    if SearchSection(rawValue: indexPath.section) == .Song {
      guard let song = songAt(indexPath.row) else { return nil }
      return PlayContext(containable: song)
    } else if SearchSection(rawValue: indexPath.section) == .Featured {
      guard let song = featuredSongAt(indexPath.row) else { return nil }
      return PlayContext(containable: song)
    } else if SearchSection(rawValue: indexPath.section) == .History {
      guard let history = searchHistoryItem(at: indexPath.row),
            let song = history.searchedPlayableContainable as? Song else { return nil }
      return PlayContext(containable: song)
    }
    return nil
  }

  // MARK: - Table view data source

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      guard let history = searchHistoryItem(at: indexPath.row) else {
        return UITableViewCell()
      }
      guard let container = history.searchedPlayableContainable else {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = history.displayName
        cell.textLabel?.textColor = .label
        cell.imageView?.image = .clock
        cell.selectionStyle = .default
        return cell
      }
      if let playlist = container as? Playlist {
        let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(playlist: playlist, rootView: self)
        return cell
      } else if let song = container as? Song {
        let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
        return cell
      } else {
        let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(container: container, rootView: self)
        return cell
      }
    case .Playlist:
      guard let playlist = playlistAt(indexPath.row) else { return UITableViewCell() }
      let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
      cell.display(playlist: playlist, rootView: self)
      return cell
    case .Artist:
      guard let artist = artistAt(indexPath.row) else { return UITableViewCell() }
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      cell.display(container: artist, rootView: self)
      return cell
    case .Album:
      guard let album = albumAt(indexPath.row) else { return UITableViewCell() }
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      cell.display(container: album, rootView: self)
      return cell
    case .Featured:
      guard let song = featuredSongAt(indexPath.row) else { return UITableViewCell() }
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    case .Song:
      guard let song = songAt(indexPath.row) else { return UITableViewCell() }
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    case .none:
      return UITableViewCell()
    }
  }

  /// The search history header has a "Clear" button. It is part of the table (not the navigation
  /// bar), because on iPhone the search tab activates the search automatically, which hides the
  /// navigation bar.
  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    // nil: default header for all other sections
    guard SearchSection(rawValue: section) == .History, !isSearchActive,
          !searchHistory.isEmpty else { return nil }

    let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
    var content = header.defaultContentConfiguration()
    content.text = tableView.dataSource?.tableView?(tableView, titleForHeaderInSection: section)
    header.contentConfiguration = content

    let clearButton = UIButton(
      type: .system,
      primaryAction: UIAction(title: "Clear") { [weak self] _ in
        self?.clearSearchHistory()
      }
    )
    clearButton.translatesAutoresizingMaskIntoConstraints = false
    clearButton.preferredBehavioralStyle = .pad
    header.contentView.addSubview(clearButton)
    NSLayoutConstraint.activate([
      clearButton.trailingAnchor
        .constraint(equalTo: header.contentView.layoutMarginsGuide.trailingAnchor),
      clearButton.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor),
    ])
    return header
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch SearchSection(rawValue: section) {
    case .History:
      return !isSearchActive ? CommonScreenOperations.tableSectionHeightLarge : 0
    case .Playlist:
      return (isSearchActive && !playlists.isEmpty) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Artist:
      return (isSearchActive && !artists.isEmpty) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Album:
      return (isSearchActive && !albums.isEmpty) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Featured:
      return (isSearchActive && !featuredSongs.isEmpty) ? CommonScreenOperations
        .tableSectionHeightLarge : 0
    case .Song:
      return (isSearchActive && !songs.isEmpty) ? CommonScreenOperations.tableSectionHeightLarge : 0
    case .none:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    viewForFooterInSection section: Int
  )
    -> UIView? {
    guard isSearchActive,
          let searchSection = SearchSection(rawValue: section),
          sectionHasMoreResults(searchSection) else { return nil }

    // Plain UIView avoids UITableViewHeaderFooterView chrome / bottom separators.
    let footer = UIView()
    footer.backgroundColor = .clear
    let showMoreButton = UIButton(
      type: .system,
      primaryAction: UIAction(title: "Show more") { [weak self] _ in
        self?.showMoreResults(in: searchSection)
      }
    )
    showMoreButton.translatesAutoresizingMaskIntoConstraints = false
    showMoreButton.preferredBehavioralStyle = .pad
    footer.addSubview(showMoreButton)
    NSLayoutConstraint.activate([
      showMoreButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
      showMoreButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])
    return footer
  }

  override func tableView(
    _ tableView: UITableView,
    heightForFooterInSection section: Int
  )
    -> CGFloat {
    guard isSearchActive,
          let searchSection = SearchSection(rawValue: section),
          sectionHasMoreResults(searchSection) else { return 0 }
    return CommonScreenOperations.tableSectionHeightLarge
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      guard let history = searchHistoryItem(at: indexPath.row),
            let container = history.searchedPlayableContainable else { return 0.0 }
      if container is Playlist {
        return PlaylistTableCell.rowHeight
      } else if container is Song {
        return PlayableTableCell.rowHeight
      } else {
        return GenericTableCell.rowHeight
      }
    case .Playlist:
      return PlaylistTableCell.rowHeight
    case .Artist:
      return GenericTableCell.rowHeight
    case .Album:
      return GenericTableCell.rowHeight
    case .Featured:
      return PlayableTableCell.rowHeight
    case .Song:
      return PlayableTableCell.rowHeight
    case .none:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch SearchSection(rawValue: indexPath.section) {
    case .History:
      guard let history = searchHistoryItem(at: indexPath.row) else { break }
      // Re-load to re-link snapshot-only items after sync brought entities back.
      searchHistory = appDelegate.storage.main.library.getSearchHistory(for: account)
      let refreshed = searchHistory.first { $0.managedObject.objectID == history.managedObject.objectID }
        ?? history
      guard let container = refreshed.searchedPlayableContainable else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: container)
      if !(container is Song) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    case .Playlist:
      guard let playlist = playlistAt(indexPath.row) else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: playlist)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
    case .Artist:
      guard let artist = artistAt(indexPath.row) else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: artist)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
    case .Album:
      guard let album = albumAt(indexPath.row) else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: album)
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    case .Featured:
      guard let song = featuredSongAt(indexPath.row) else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: song)
    case .Song:
      guard let song = songAt(indexPath.row) else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: song)
    case .none: break
    }
    appDelegate.storage.main.library.saveContext()
  }

  struct SearchResultObjectContainer: Sendable {
    var artistsIDs = [NSManagedObjectID]()
    var albumsIDs = [NSManagedObjectID]()
    var playlistsIDs = [NSManagedObjectID]()
    var featuredSongsIDs = [NSManagedObjectID]()
    var songsIDs = [NSManagedObjectID]()
  }

  nonisolated private static func rankedSongIDs(
    from songs: [Song],
    searchText: String
  )
    -> [NSManagedObjectID] {
    FuzzySearcher.findBestMatch(in: songs, search: searchText)
      .prefix(upToAsArray: categoryResultCap)
      .compactMap { $0 as? Song }
      .compactMap { $0.managedObject.objectID }
  }

  /// Featured matches are on credit text, not title — keep Core Data order and skip Fuse filtering.
  nonisolated private static func featuredSongIDs(
    from songs: [Song],
    excluding excludedIDs: Set<NSManagedObjectID>
  )
    -> [NSManagedObjectID] {
    songs
      .map(\.managedObject.objectID)
      .filter { !excludedIDs.contains($0) }
      .prefix(upToAsArray: categoryResultCap)
  }

  private func applySearchResult(_ searchResult: SearchResultObjectContainer) {
    isSearchActive = true
    searchHistory = []
    resetPaginationVisibleCounts()
    allArtistsIDs = searchResult.artistsIDs
    allAlbumsIDs = searchResult.albumsIDs
    allPlaylistsIDs = searchResult.playlistsIDs
    allFeaturedSongsIDs = searchResult.featuredSongsIDs
    allSongsIDs = searchResult.songsIDs
    resolveDisplayedResults()
    // Snapshot first — separatorStyle / unavailable content can force layout against
    // the previous snapshot while arrays already match the new results.
    updateDataSource(animated: false)
    tableView.separatorStyle = .singleLine
    updateContentUnavailable()
  }

  private func applyFeaturedAndSongsResult(
    featuredSongsIDs: [NSManagedObjectID],
    songsIDs: [NSManagedObjectID]
  ) {
    allFeaturedSongsIDs = featuredSongsIDs
    allSongsIDs = songsIDs
    featuredVisibleCount = min(featuredVisibleCount, max(featuredSongsIDs.count, 0))
    songsVisibleCount = min(songsVisibleCount, max(songsIDs.count, 0))
    if featuredVisibleCount == 0, !featuredSongsIDs.isEmpty {
      featuredVisibleCount = min(Self.categoryPageSize, featuredSongsIDs.count)
    }
    if songsVisibleCount == 0, !songsIDs.isEmpty {
      songsVisibleCount = min(Self.categoryPageSize, songsIDs.count)
    }
    resolveDisplayedResults()
    updateDataSource(animated: false, reloadingSections: [.Featured, .Song])
    updateContentUnavailable()
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text, let accountObjectId else { return }
    searchGeneration += 1
    let generation = searchGeneration

    if !searchText.isEmpty, !searchController.searchBar.isCachedScopeSelected {
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchArtists(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Artists Search", error: error)
      }}

      Task { @MainActor in do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchAlbums(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Albums Search", error: error)
      }}

      Task { @MainActor in
        do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .searchSongs(searchText: searchText)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Songs Search", error: error)
        }
        guard generation == self.searchGeneration,
              searchText == self.searchController.searchBar.text,
              !self.searchController.searchBar.isCachedScopeSelected else { return }
        do {
          let refreshed = try await self.appDelegate.storage.async.performAndGet { asyncCompanion in
            let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
            let songs = asyncCompanion.library.searchSongs(
              for: accountAsync,
              searchText: searchText,
              onlyCached: false,
              displayFilter: .all
            )
            let featured = asyncCompanion.library.searchFeaturedSongs(
              for: accountAsync,
              searchText: searchText,
              onlyCached: false,
              displayFilter: .all
            )
            let songsIDs = Self.rankedSongIDs(from: songs, searchText: searchText)
            let featuredSongsIDs = Self.featuredSongIDs(
              from: featured,
              excluding: Set(songsIDs)
            )
            return (featuredSongsIDs, songsIDs)
          }
          guard generation == self.searchGeneration,
                searchText == self.searchController.searchBar.text,
                !self.searchController.searchBar.isCachedScopeSelected else { return }
          self.applyFeaturedAndSongsResult(
            featuredSongsIDs: refreshed.0,
            songsIDs: refreshed.1
          )
        } catch {
          // do nothing
        }
      }

      Task { @MainActor in do {
        let searchResult = try await appDelegate.storage.async.performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          let artists = asyncCompanion.library.searchArtists(
            for: accountAsync,
            searchText: searchText,
            onlyCached: false,
            displayFilter: .all
          )
          let albums = asyncCompanion.library.searchAlbums(
            for: accountAsync,
            searchText: searchText,
            onlyCached: false,
            displayFilter: .all
          )
          let playlists = asyncCompanion.library.searchPlaylists(
            for: accountAsync,
            searchText: searchText,
            playlistSearchCategory: .all
          )
          let songs = asyncCompanion.library.searchSongs(
            for: accountAsync,
            searchText: searchText,
            onlyCached: false,
            displayFilter: .all
          )
          let featured = asyncCompanion.library.searchFeaturedSongs(
            for: accountAsync,
            searchText: searchText,
            onlyCached: false,
            displayFilter: .all
          )

          var result = SearchResultObjectContainer()
          result.artistsIDs = FuzzySearcher.findBestMatch(in: artists, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Artist }
            .compactMap { $0.managedObject.objectID }
          result.albumsIDs = FuzzySearcher.findBestMatch(in: albums, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Album }
            .compactMap { $0.managedObject.objectID }
          result.playlistsIDs = FuzzySearcher.findBestMatch(in: playlists, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Playlist }
            .compactMap { $0.managedObject.objectID }
          result.songsIDs = Self.rankedSongIDs(from: songs, searchText: searchText)
          result.featuredSongsIDs = Self.featuredSongIDs(
            from: featured,
            excluding: Set(result.songsIDs)
          )
          return result
        }

        guard generation == self.searchGeneration,
              searchText == self.searchController.searchBar.text else { return }
        self.applySearchResult(searchResult)
      } catch {
        // do nothing
      }}
    } else if !searchText.isEmpty, searchController.searchBar.isCachedScopeSelected {
      Task { @MainActor in do {
        let searchResult = try await appDelegate.storage.async.performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          let artists = asyncCompanion.library.searchArtists(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )
          let albums = asyncCompanion.library.searchAlbums(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )
          let playlists = asyncCompanion.library.searchPlaylists(
            for: accountAsync,
            searchText: searchText,
            playlistSearchCategory: .cached
          )
          let songs = asyncCompanion.library.searchSongs(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )
          let featured = asyncCompanion.library.searchFeaturedSongs(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )

          var result = SearchResultObjectContainer()
          result.artistsIDs = FuzzySearcher.findBestMatch(in: artists, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Artist }
            .compactMap { $0.managedObject.objectID }
          result.albumsIDs = FuzzySearcher.findBestMatch(in: albums, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Album }
            .compactMap { $0.managedObject.objectID }
          result.playlistsIDs = FuzzySearcher.findBestMatch(in: playlists, search: searchText)
            .prefix(upToAsArray: Self.categoryResultCap)
            .compactMap { $0 as? Playlist }
            .compactMap { $0.managedObject.objectID }
          result.songsIDs = Self.rankedSongIDs(from: songs, searchText: searchText)
          result.featuredSongsIDs = Self.featuredSongIDs(
            from: featured,
            excluding: Set(result.songsIDs)
          )
          return result
        }

        guard generation == self.searchGeneration,
              searchText == self.searchController.searchBar.text else { return }
        self.applySearchResult(searchResult)
      } catch {
        // do nothing
      }}
    } else {
      reloadSearchHistory()
    }
  }

  func updateContentUnavailable() {
    if isSearchActive {
      if artists.isEmpty, albums.isEmpty, playlists.isEmpty, featuredSongs.isEmpty, songs.isEmpty {
        setAmperfyUnavailableContent(.search())
      } else {
        setAmperfyUnavailableContent(nil)
      }
    } else {
      setAmperfyUnavailableContent(searchHistory.isEmpty ? noSearchHistoryConfig : nil)
    }
  }

  lazy var noSearchHistoryConfig: AmperfyUnavailableContent = {
    .empty(image: .clock, text: "No Search History", secondaryText: "Your search history will appear here.")
  }()
}
