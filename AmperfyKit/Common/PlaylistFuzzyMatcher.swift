//
//  PlaylistFuzzyMatcher.swift
//  AmperfyKit
//
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import Foundation

// MARK: - PlaylistMatchScore

public struct PlaylistMatchScore: Sendable {
  public let titleScore: Int
  public let artistScore: Int
  public let combined: Int
  public let passesThreshold: Bool
}

// MARK: - PlaylistFuzzyMatcher

/// Title/artist scoring for pasted playlist lines. Scores are 0...100, higher is better
/// (same idea as fuzzywuzzy ratio, not Ifrit Fuse).
public enum PlaylistFuzzyMatcher {
  public static let titleThreshold = 70
  public static let artistThreshold = 85
  /// Extra words that make a recording different from the requested studio track.
  /// Thresholds stay the same; callers skip auto-select when the candidate adds one of these.
  public static let versionMarkers = ["live", "remix", "acoustic", "remaster", "deluxe"]

  /// `Artist - Title`. A line without ` - ` is treated as a title-only query.
  public static func parseLine(_ line: String) -> (artist: String, title: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let separator = trimmed.range(of: " - ") {
      let artist = clean(String(trimmed[..<separator.lowerBound]))
      let title = clean(String(trimmed[separator.upperBound...]))
      guard !title.isEmpty else { return nil }
      return (artist, title)
    }

    let title = clean(trimmed)
    guard !title.isEmpty else { return nil }
    return ("", title)
  }

  public static func score(
    queryTitle: String,
    queryArtist: String,
    candidateTitle: String,
    candidateArtist: String
  )
    -> PlaylistMatchScore {
    let titleScore = ratio(queryTitle, candidateTitle)
    let artistQuery = normalize(queryArtist)
    let artistScore = artistQuery.isEmpty
      ? 100
      : partialRatio(queryArtist, candidateArtist)
    let combined = artistQuery.isEmpty
      ? titleScore
      : (titleScore + artistScore) / 2
    let passes = artistQuery.isEmpty
      ? titleScore >= titleThreshold
      : titleScore >= titleThreshold && artistScore >= artistThreshold
    return PlaylistMatchScore(
      titleScore: titleScore,
      artistScore: artistScore,
      combined: combined,
      passesThreshold: passes
    )
  }

  /// True when the candidate title introduces a version the query does not mention.
  public static func addsVersionMarker(queryTitle: String, candidateTitle: String) -> Bool {
    let query = versionMarkerSet(queryTitle)
    let candidate = versionMarkerSet(candidateTitle)
    return !candidate.subtracting(query).isEmpty
  }

  private static func versionMarkerSet(_ title: String) -> Set<String> {
    let tokens = normalize(title).split { !$0.isLetter }.map(String.init)
    var found = Set<String>()
    for marker in versionMarkers {
      if tokens.contains(where: { $0 == marker || $0.hasPrefix(marker) }) {
        found.insert(marker)
      }
    }
    return found
  }

  public static func clean(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = value.lowercased()
    for ext in ["mp3", "flac", "m4a", "ogg", "wav", "aiff", "wma", "aac", "alac"] {
      let suffix = "." + ext
      if lower.hasSuffix(suffix) {
        value = String(value.dropLast(suffix.count))
        break
      }
    }
    return normalize(value)
  }

  /// Full-string similarity, 0...100.
  public static func ratio(_ a: String, _ b: String) -> Int {
    let left = normalize(a)
    let right = normalize(b)
    if left.isEmpty || right.isEmpty { return 0 }
    if left == right { return 100 }
    let distance = levenshtein(Array(left), Array(right))
    let maxLen = max(left.count, right.count)
    return Int((1.0 - (Double(distance) / Double(maxLen))) * 100.0)
  }

  /// Best ratio of the shorter string against windows of the longer one.
  public static func partialRatio(_ a: String, _ b: String) -> Int {
    let left = normalize(a)
    let right = normalize(b)
    if left.isEmpty || right.isEmpty { return 0 }
    if left == right || left.contains(right) || right.contains(left) { return 100 }
    let (short, long) = left.count <= right.count ? (left, right) : (right, left)
    let shortChars = Array(short)
    let longChars = Array(long)
    let window = shortChars.count
    guard longChars.count >= window, window > 0 else { return ratio(short, long) }
    var best = 0
    var index = 0
    while index + window <= longChars.count {
      let slice = String(longChars[index ..< (index + window)])
      best = max(best, ratio(short, slice))
      if best == 100 { break }
      index += 1
    }
    return best
  }

  private static func normalize(_ text: String) -> String {
    text
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func levenshtein(_ left: [Character], _ right: [Character]) -> Int {
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }
    var previous = Array(0 ... right.count)
    var current = Array(repeating: 0, count: right.count + 1)
    for (i, leftChar) in left.enumerated() {
      current[0] = i + 1
      for (j, rightChar) in right.enumerated() {
        let cost = leftChar == rightChar ? 0 : 1
        current[j + 1] = min(
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost
        )
      }
      swap(&previous, &current)
    }
    return previous[right.count]
  }
}
