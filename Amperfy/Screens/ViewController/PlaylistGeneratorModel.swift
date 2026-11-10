//
//  PlaylistGeneratorModel.swift
//  Amperfy
//
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import AmperfyKit
import CoreData
import Foundation
import UIKit

// MARK: - PlaylistMatchStatus

enum PlaylistMatchStatus {
  case matched
  case needsReview
  case missing
}

// MARK: - PlaylistSongCandidate

struct PlaylistSongCandidate: Identifiable, Hashable {
  let objectID: NSManagedObjectID
  let remoteID: String
  let title: String
  let artist: String
  let album: String
  let titleScore: Int
  let artistScore: Int
  let combined: Int
  let passesThreshold: Bool
  let versionMismatch: Bool

  var id: NSManagedObjectID { objectID }

  var subtitle: String {
    [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

// MARK: - PlaylistMatchRow

struct PlaylistMatchRow: Identifiable {
  let id: UUID
  let raw: String
  let artist: String
  let title: String
  var candidates: [PlaylistSongCandidate]
  var manualResults: [PlaylistSongCandidate]
  var selected: PlaylistSongCandidate?
  /// User confirmed this selection, or it was an unambiguous auto-match.
  var confirmed: Bool
  /// User explicitly skipped this line.
  var skipped: Bool
  var didSearch: Bool
  var error: String?
  var manualQuery: String

  var queryTitle: String { title }

  var querySubtitle: String { artist }

  var status: PlaylistMatchStatus {
    if confirmed, selected != nil { return .matched }
    if skipped { return .missing }
    if didSearch, candidates.isEmpty, manualResults.isEmpty { return .missing }
    if didSearch { return .needsReview }
    return .missing
  }

  /// Best unconfirmed suggestion, shown in the match column until the user picks.
  var suggestion: PlaylistSongCandidate? {
    candidates.first ?? manualResults.first
  }
}

// MARK: - PlaylistCreateOutcome

enum PlaylistCreateOutcome {
  case success(Playlist)
  case failure(message: String)
}

// MARK: - PlaylistGeneratorModel

@MainActor
final class PlaylistGeneratorModel: ObservableObject {
  let account: Account

  @Published
  var playlistName = ""
  @Published
  var pasteText = ""
  @Published
  var rows: [PlaylistMatchRow] = []
  @Published
  var isMatching = false
  @Published
  var isCreating = false
  @Published
  var progressText = ""
  @Published
  var statusMessage = ""
  @Published
  var inputExpanded = true
  @Published
  var reviewingRowID: UUID?
  @Published
  var searchingRowID: UUID?

  private var matchTask: Task<(), Never>?
  private var matchGeneration = 0
  private var manualGeneration: [UUID: Int] = [:]

  init(account: Account) {
    self.account = account
  }

  var matchedCount: Int { rows.filter { $0.status == .matched }.count }
  var reviewCount: Int { rows.filter { $0.status == .needsReview }.count }
  var missingCount: Int { rows.filter { $0.status == .missing }.count }

  var canCreate: Bool {
    !isMatching && !isCreating && matchedCount > 0
  }

  var reviewingRow: PlaylistMatchRow? {
    guard let reviewingRowID else { return nil }
    return rows.first { $0.id == reviewingRowID }
  }

  func toggleInput() {
    inputExpanded.toggle()
  }

  func openReview(for id: UUID) {
    reviewingRowID = id
  }

  func closeReview() {
    reviewingRowID = nil
  }

  func moveRows(from source: IndexSet, to destination: Int) {
    rows.move(fromOffsets: source, toOffset: destination)
  }

  func deleteRow(id: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    let row = rows.remove(at: index)
    if reviewingRowID == id { reviewingRowID = nil }
    manualGeneration[id] = nil
    removePasteLine(matching: row)
    if rows.isEmpty {
      inputExpanded = true
      statusMessage = ""
    }
  }

  /// Appends one `Artist - Title` line and matches only that row.
  @discardableResult
  func addTrack(line: String) async -> Bool {
    let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isMatching, let parsed = PlaylistFuzzyMatcher.parseLine(raw) else { return false }
    let row = PlaylistMatchRow(
      id: UUID(),
      raw: raw,
      artist: parsed.artist,
      title: parsed.title,
      candidates: [],
      manualResults: [],
      selected: nil,
      confirmed: false,
      skipped: false,
      didSearch: false,
      error: nil,
      manualQuery: ""
    )
    rows.append(row)
    let existing = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
    pasteText = existing.isEmpty ? raw : existing + "\n" + raw
    await matchRow(id: row.id, generation: matchGeneration)
    return true
  }

  func cancelMatch() {
    matchGeneration += 1
    matchTask?.cancel()
    matchTask = nil
    isMatching = false
    progressText = ""
  }

  func startMatch() {
    matchTask?.cancel()
    matchGeneration += 1
    let generation = matchGeneration

    let parsed = parseLines(pasteText)
    var pool = rows
    var next: [PlaylistMatchRow] = []
    var pending: [UUID] = []
    for line in parsed {
      if let index = pool.firstIndex(where: {
        $0.didSearch && $0.artist == line.artist && $0.title == line.title
      }) {
        next.append(pool.remove(at: index))
      } else {
        let row = PlaylistMatchRow(
          id: UUID(),
          raw: line.raw,
          artist: line.artist,
          title: line.title,
          candidates: [],
          manualResults: [],
          selected: nil,
          confirmed: false,
          skipped: false,
          didSearch: false,
          error: nil,
          manualQuery: ""
        )
        next.append(row)
        pending.append(row.id)
      }
    }
    rows = next
    reviewingRowID = nil
    statusMessage = rows.isEmpty ? "Paste one song per line: Artist - Title" : ""
    guard !pending.isEmpty else {
      inputExpanded = rows.isEmpty
      return
    }

    isMatching = true
    let total = pending.count
    matchTask = Task { [weak self] in
      guard let self else { return }
      for (offset, id) in pending.enumerated() {
        if Task.isCancelled || generation != matchGeneration { return }
        progressText = "Matching \(offset + 1) of \(total)"
        await matchRow(id: id, generation: generation)
      }
      guard generation == matchGeneration, !Task.isCancelled else { return }
      isMatching = false
      progressText = ""
      inputExpanded = false
      statusMessage = ""
    }
  }

  func select(_ candidate: PlaylistSongCandidate?, for rowID: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    rows[index].selected = candidate
    rows[index].confirmed = candidate != nil
    rows[index].skipped = candidate == nil
    reviewingRowID = nil
  }

  func updateManualQuery(_ text: String, for rowID: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    rows[index].manualQuery = text
  }

  func searchManually(rowID: UUID) async {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    let query = rows[index].manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    manualGeneration[rowID, default: 0] += 1
    let generation = manualGeneration[rowID, default: 0]
    searchingRowID = rowID
    defer {
      if searchingRowID == rowID { searchingRowID = nil }
    }
    do {
      let ids = try await appDelegate.getMeta(account.info).librarySyncer
        .searchSongMatches(searchText: query)
      guard manualGeneration[rowID] == generation else { return }
      guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
      rows[index].manualResults = candidates(
        for: ids,
        queryTitle: rows[index].title,
        queryArtist: rows[index].artist
      )
      rows[index].error = nil
    } catch {
      guard manualGeneration[rowID] == generation else { return }
      guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
      rows[index].error = error.localizedDescription
    }
  }

  func createPlaylist() async -> PlaylistCreateOutcome {
    let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      return .failure(message: "Enter a playlist name.")
    }
    let songs: [Song] = rows.compactMap { row in
      guard row.status == .matched, let selected = row.selected, !selected.remoteID.isEmpty
      else { return nil }
      guard let managed = try? appDelegate.storage.main.context
        .existingObject(with: selected.objectID) as? SongMO
      else { return nil }
      return Song(managedObject: managed)
    }
    guard !songs.isEmpty else {
      return .failure(
        message: "No confirmed songs to add. Match at least one song, then try again."
      )
    }

    isCreating = true
    statusMessage = ""
    defer { isCreating = false }

    let playlist = appDelegate.storage.main.library.createPlaylist(account: account)
    playlist.name = name
    appDelegate.storage.main.saveContext()

    do {
      try await appDelegate.getMeta(account.info).librarySyncer.syncUpload(
        playlistToAddSongs: playlist,
        songs: songs
      )
      playlist.append(playables: songs)
      let songWord = songs.count == 1 ? "song" : "songs"
      statusMessage = "Created “\(name)” with \(songs.count) \(songWord)."
      appDelegate.eventLogger.info(topic: "Playlist Generator", message: statusMessage)
      return .success(playlist)
    } catch {
      let remoteID = playlist.id
      appDelegate.storage.main.library.deletePlaylist(playlist)
      appDelegate.storage.main.saveContext()
      if !remoteID.isEmpty {
        try? await appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistIdToDelete: remoteID)
      }
      appDelegate.eventLogger.report(topic: "Playlist Generator", error: error)
      return .failure(message: Self.creationErrorMessage(for: error))
    }
  }

  private static func creationErrorMessage(for error: Error) -> String {
    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if detail.isEmpty {
      return "The playlist could not be created. Check your connection and try again."
    }
    return "\(detail) The playlist was not saved. Try again."
  }

  private var appDelegate: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  private struct ParsedLine {
    let raw: String
    let artist: String
    let title: String
  }

  private func removePasteLine(matching row: PlaylistMatchRow) {
    var lines = pasteText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let index = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces) == row.raw
    }) {
      lines.remove(at: index)
    } else if let index = lines.firstIndex(where: {
      guard let parsed = PlaylistFuzzyMatcher.parseLine($0) else { return false }
      return parsed.artist == row.artist && parsed.title == row.title
    }) {
      lines.remove(at: index)
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeLast()
    }
    pasteText = lines.joined(separator: "\n")
  }

  private func parseLines(_ text: String) -> [ParsedLine] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let raw = String(line)
      guard let parsed = PlaylistFuzzyMatcher.parseLine(raw) else { return nil }
      return ParsedLine(raw: raw, artist: parsed.artist, title: parsed.title)
    }
  }

  private func matchRow(id: UUID, generation: Int) async {
    guard let row = rows.first(where: { $0.id == id }) else { return }
    let artist = row.artist
    let title = row.title
    let query = artist.isEmpty ? title : "\(artist) \(title)"
    do {
      let ids = try await appDelegate.getMeta(account.info).librarySyncer
        .searchSongMatches(searchText: query)
      guard generation == matchGeneration, !Task.isCancelled else { return }
      guard let index = rows.firstIndex(where: {
        $0.id == id && $0.artist == artist && $0.title == title
      }) else { return }
      let scored = candidates(for: ids, queryTitle: title, queryArtist: artist)
      rows[index].candidates = scored
      rows[index].didSearch = true
      rows[index].error = nil
      if let best = scored.first(where: { $0.passesThreshold && !$0.versionMismatch }) {
        rows[index].selected = best
        rows[index].confirmed = true
        rows[index].skipped = false
      } else {
        rows[index].selected = nil
        rows[index].confirmed = false
      }
    } catch {
      guard generation == matchGeneration, !Task.isCancelled else { return }
      guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
      rows[index].error = error.localizedDescription
      rows[index].candidates = []
      rows[index].selected = nil
      rows[index].confirmed = false
      rows[index].didSearch = true
    }
  }

  private func candidates(
    for ids: [NSManagedObjectID],
    queryTitle: String,
    queryArtist: String
  )
    -> [PlaylistSongCandidate] {
    let context = appDelegate.storage.main.context
    var seen = Set<NSManagedObjectID>()
    var scored: [PlaylistSongCandidate] = []
    for id in ids {
      guard seen.insert(id).inserted,
            let managed = try? context.existingObject(with: id) as? SongMO
      else { continue }
      let song = Song(managedObject: managed)
      guard !song.id.isEmpty else { continue }
      let artistName = song.artist?.name ?? ""
      let match = PlaylistFuzzyMatcher.score(
        queryTitle: queryTitle,
        queryArtist: queryArtist,
        candidateTitle: song.title,
        candidateArtist: artistName
      )
      scored.append(PlaylistSongCandidate(
        objectID: id,
        remoteID: song.id,
        title: song.title,
        artist: artistName,
        album: song.album?.name ?? "",
        titleScore: match.titleScore,
        artistScore: match.artistScore,
        combined: match.combined,
        passesThreshold: match.passesThreshold,
        versionMismatch: PlaylistFuzzyMatcher.addsVersionMarker(
          queryTitle: queryTitle,
          candidateTitle: song.title
        )
      ))
    }
    scored.sort { lhs, rhs in
      let lhsRank = rank(lhs)
      let rhsRank = rank(rhs)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      if lhs.combined != rhs.combined { return lhs.combined > rhs.combined }
      return lhs.titleScore > rhs.titleScore
    }
    return scored
  }

  private func rank(_ candidate: PlaylistSongCandidate) -> Int {
    if candidate.passesThreshold, !candidate.versionMismatch { return 0 }
    if candidate.passesThreshold { return 1 }
    return 2
  }
}
