//
//  SearchHistory.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 21.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

import Foundation

public enum SearchHistoryEntityType: String {
  case song
  case album
  case artist
  case playlist
  case podcast
  case episode
}

public class SearchHistoryItem: NSObject {
  public let managedObject: SearchHistoryItemMO

  public init(managedObject: SearchHistoryItemMO) {
    self.managedObject = managedObject
  }

  public var account: Account? {
    get {
      guard let accountMO = managedObject.account else { return nil }
      return Account(managedObject: accountMO)
    }
    set {
      if managedObject.account != newValue?
        .managedObject { managedObject.account = newValue?.managedObject }
    }
  }

  public var date: Date? {
    get { managedObject.date }
    set { managedObject.date = newValue }
  }

  public var searchedEntityType: String? {
    get { managedObject.searchedEntityType }
    set {
      if managedObject.searchedEntityType != newValue {
        managedObject.searchedEntityType = newValue
      }
    }
  }

  public var searchedEntityId: String? {
    get { managedObject.searchedEntityId }
    set {
      if managedObject.searchedEntityId != newValue {
        managedObject.searchedEntityId = newValue
      }
    }
  }

  public var searchedEntityName: String? {
    get { managedObject.searchedEntityName }
    set {
      if managedObject.searchedEntityName != newValue {
        managedObject.searchedEntityName = newValue
      }
    }
  }

  /// Live container when linked, otherwise nil (use `displayName` for snapshot-only rows).
  public var searchedPlayableContainable: PlayableContainable? {
    get {
      if let searchedLibraryEntityMO = managedObject.searchedLibraryEntity {
        if let songMO = searchedLibraryEntityMO as? SongMO {
          return Song(managedObject: songMO)
        } else if let episodeMO = searchedLibraryEntityMO as? PodcastEpisodeMO {
          return PodcastEpisode(managedObject: episodeMO)
        } else if let albumMO = searchedLibraryEntityMO as? AlbumMO {
          return Album(managedObject: albumMO)
        } else if let artistMO = searchedLibraryEntityMO as? ArtistMO {
          return Artist(managedObject: artistMO)
        } else if let podcastMO = searchedLibraryEntityMO as? PodcastMO {
          return Podcast(managedObject: podcastMO)
        } else {
          return nil
        }
      } else if let playlistMO = managedObject.searchedPlaylist {
        guard let context = managedObject.managedObjectContext else { return nil }
        return Playlist(library: LibraryStorage(context: context), managedObject: playlistMO)
      } else {
        return nil
      }
    }

    set {
      if let song = newValue as? Song {
        managedObject.searchedLibraryEntity = song.managedObject
        managedObject.searchedPlaylist = nil
      } else if let episode = newValue as? PodcastEpisode {
        managedObject.searchedLibraryEntity = episode.managedObject
        managedObject.searchedPlaylist = nil
      } else if let album = newValue as? Album {
        managedObject.searchedLibraryEntity = album.managedObject
        managedObject.searchedPlaylist = nil
      } else if let artist = newValue as? Artist {
        managedObject.searchedLibraryEntity = artist.managedObject
        managedObject.searchedPlaylist = nil
      } else if let podcast = newValue as? Podcast {
        managedObject.searchedLibraryEntity = podcast.managedObject
        managedObject.searchedPlaylist = nil
      } else if let playlist = newValue as? Playlist {
        managedObject.searchedLibraryEntity = nil
        managedObject.searchedPlaylist = playlist.managedObject
      }
    }
  }

  public var displayName: String {
    if let container = searchedPlayableContainable {
      return container.name
    }
    return searchedEntityName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? "Unknown"
  }

  public func applySnapshot(from container: PlayableContainable) {
    if let song = container as? Song {
      searchedEntityType = SearchHistoryEntityType.song.rawValue
      searchedEntityId = song.id
      searchedEntityName = song.name
    } else if let episode = container as? PodcastEpisode {
      searchedEntityType = SearchHistoryEntityType.episode.rawValue
      searchedEntityId = episode.id
      searchedEntityName = episode.name
    } else if let album = container as? Album {
      searchedEntityType = SearchHistoryEntityType.album.rawValue
      searchedEntityId = album.id
      searchedEntityName = album.name
    } else if let artist = container as? Artist {
      searchedEntityType = SearchHistoryEntityType.artist.rawValue
      searchedEntityId = artist.id
      searchedEntityName = artist.name
    } else if let podcast = container as? Podcast {
      searchedEntityType = SearchHistoryEntityType.podcast.rawValue
      searchedEntityId = podcast.id
      searchedEntityName = podcast.name
    } else if let playlist = container as? Playlist {
      searchedEntityType = SearchHistoryEntityType.playlist.rawValue
      searchedEntityId = playlist.id
      searchedEntityName = playlist.name
    }
  }

  override public func isEqual(_ object: Any?) -> Bool {
    guard let object = object as? SearchHistoryItem else { return false }
    return managedObject == object.managedObject
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
