//
//  DirectorySongListModel.swift
//  Amperfy
//
//  Recursively scans a folder for audio files and builds Artist - Title lines
//  (same idea as Helper/song-list-from-dir.sh), shown in-app.
//

import AVFoundation
import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - DirectorySongListEntry

struct DirectorySongListEntry: Identifiable, Hashable {
  let id: URL
  let artist: String
  let title: String
  let relativePath: String

  var displayLine: String { "\(artist) - \(title)" }
}

// MARK: - DirectorySongListModel

@MainActor
final class DirectorySongListModel: ObservableObject {
  @Published
  var folderPath = ""
  @Published
  var entries: [DirectorySongListEntry] = []
  @Published
  var isScanning = false
  @Published
  var progressText = ""
  @Published
  var statusMessage = ""
  @Published
  var sortAlphabetically = true
  @Published
  var uniqueOnly = false

  private var scanTask: Task<(), Never>?
  private var securityScopedURL: URL?

  var canScan: Bool {
    !isScanning && resolvedScanURL() != nil
  }

  var displayLines: [String] {
    var lines = entries.map(\.displayLine)
    if uniqueOnly {
      var seen = Set<String>()
      lines = lines.filter { line in
        let key = line.caseFolded
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
      }
    }
    if sortAlphabetically {
      lines.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    return lines
  }

  func setFolderURL(_ url: URL) {
    stopSecurityAccess()
    let accessing = url.startAccessingSecurityScopedResource()
    if accessing {
      securityScopedURL = url
    }
    folderPath = url.path
    statusMessage = ""
    entries = []
  }

  func clearResults() {
    entries = []
    progressText = ""
    statusMessage = ""
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    isScanning = false
    progressText = ""
  }

  func startScan() {
    cancelScan()
    guard let root = resolvedScanURL() else {
      let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("smb://") {
        statusMessage =
          "Could not map that smb:// path to a mounted volume. Mount the share in Finder, or use Browse…"
      } else {
        statusMessage = "Enter a folder path or choose a folder."
      }
      return
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue
    else {
      statusMessage = "Folder not found. Mount the share or pick a folder you can access."
      return
    }

    // Keep security scope for Browse-picked folders across the scan.
    if let scoped = securityScopedURL, scoped.standardizedFileURL == root.standardizedFileURL {
      _ = scoped.startAccessingSecurityScopedResource()
    } else {
      _ = root.startAccessingSecurityScopedResource()
    }

    // Fail fast with a clear message when the sandbox blocks listing.
    do {
      _ = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      statusMessage =
        "Can't read this folder (permission denied). Use Browse… to grant access, or remount the share."
      return
    }

    isScanning = true
    progressText = "Scanning…"
    statusMessage = ""
    entries = []

    let sort = sortAlphabetically
    scanTask = Task { [weak self] in
      let collected = await DirectorySongListScanner.scanFolder(root: root) { count in
        Task { @MainActor in
          self?.progressText = "Found \(count) audio file\(count == 1 ? "" : "s")…"
        }
      }
      guard let self, !Task.isCancelled else { return }
      var result = collected.entries
      if sort {
        result.sort {
          $0.displayLine.localizedStandardCompare($1.displayLine) == .orderedAscending
        }
      }
      self.entries = result
      self.isScanning = false
      self.progressText = ""
      if result.isEmpty {
        if collected.visitedFileCount == 0, collected.listedDirectoryCount == 0 {
          self.statusMessage =
            "Can't read files in this folder. Use Browse… to grant access."
        } else if collected.visitedFileCount == 0 {
          self.statusMessage = "This folder has no files to scan."
        } else {
          self.statusMessage = "No audio files found in this folder."
        }
      } else {
        self.statusMessage = "\(result.count) song\(result.count == 1 ? "" : "s") found."
      }
    }
  }

  func copyListToPasteboard() {
    let text = displayLines.joined(separator: "\n")
    guard !text.isEmpty else { return }
    UIPasteboard.general.string = text + "\n"
    statusMessage = "Copied \(displayLines.count) line\(displayLines.count == 1 ? "" : "s")."
  }

  func cleanup() {
    stopSecurityAccess()
    cancelScan()
  }

  private func stopSecurityAccess() {
    securityScopedURL?.stopAccessingSecurityScopedResource()
    securityScopedURL = nil
  }

  private func resolvedScanURL() -> URL? {
    let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("smb://") {
      return Self.mapSMBPath(trimmed)
    }
    // Prefer the security-scoped URL when the typed path still matches Browse.
    if let scoped = securityScopedURL, scoped.path == trimmed || scoped.path == (trimmed as NSString).expandingTildeInPath {
      return scoped
    }
    return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
  }

  /// Best-effort smb://host/share/rest → /Volumes/… mapping (same idea as the helper script).
  private static func mapSMBPath(_ raw: String) -> URL? {
    let without = String(raw.dropFirst("smb://".count))
    let host = without.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? ""
    var afterHost = without
    if let range = afterHost.range(of: host) {
      afterHost.removeSubrange(range)
    }
    afterHost = afterHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let share = afterHost.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    var rest = afterHost
    if let range = rest.range(of: share) {
      rest.removeSubrange(range)
    }
    rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    var candidates = [String]()
    if !share.isEmpty { candidates.append("/Volumes/\(share)/\(rest)") }
    candidates.append("/Volumes/\(host)/\(rest)")
    if !share.isEmpty { candidates.append("/Volumes/\(host)/\(share)/\(rest)") }
    // Single-letter Windows drive share (e.g. D) often mounts as host-only volume.
    if share.count == 1, share.rangeOfCharacter(from: .letters) != nil {
      candidates.append("/Volumes/\(host)/\(rest)")
    }

    let fm = FileManager.default
    for path in candidates {
      let cleaned = path.hasSuffix("/") ? String(path.dropLast()) : path
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: cleaned, isDirectory: &isDir), isDir.boolValue {
        return URL(fileURLWithPath: cleaned)
      }
    }
    return nil
  }

}

// MARK: - DirectorySongListScanner

private struct DirectorySongListScanResult: Sendable {
  var entries: [DirectorySongListEntry]
  var visitedFileCount: Int
  var listedDirectoryCount: Int
}

private enum DirectorySongListScanner {
  static let audioExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "aac", "flac", "alac", "wav", "aiff", "aif", "ogg", "opus", "wma",
  ]

  static func scanFolder(
    root: URL,
    progress: @escaping @Sendable (Int) -> ()
  ) async
    -> DirectorySongListScanResult {
    await Task.detached(priority: .userInitiated) {
      walk(root: root, progress: progress)
    }.value
  }

  nonisolated private static func walk(
    root: URL,
    progress: @escaping @Sendable (Int) -> ()
  )
    -> DirectorySongListScanResult {
    var results = [DirectorySongListEntry]()
    var visitedFileCount = 0
    var listedDirectoryCount = 0
    let fm = FileManager.default

    // Recursive contentsOfDirectory is more reliable than enumerator on some
    // SMB mounts under App Sandbox / Mac Catalyst.
    var stack = [root]
    while let dir = stack.popLast() {
      if Task.isCancelled { break }
      let children: [URL]
      do {
        children = try fm.contentsOfDirectory(
          at: dir,
          includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
          options: [.skipsHiddenFiles]
        )
        listedDirectoryCount += 1
      } catch {
        continue
      }

      for child in children {
        if Task.isCancelled { break }
        let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
          stack.append(child)
          continue
        }
        // Some network volumes omit resource values; fall back to path checks.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
          stack.append(child)
          continue
        }
        visitedFileCount += 1
        let ext = child.pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { continue }

        let (artist, title) = readTags(for: child)
        let relative = child.path.replacingOccurrences(of: root.path, with: "")
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        results.append(
          DirectorySongListEntry(
            id: child,
            artist: artist,
            title: title,
            relativePath: relative
          )
        )
        if results.count % 25 == 0 {
          progress(results.count)
        }
      }
    }

    progress(results.count)
    return DirectorySongListScanResult(
      entries: results,
      visitedFileCount: visitedFileCount,
      listedDirectoryCount: listedDirectoryCount
    )
  }

  nonisolated static func readTags(for url: URL) -> (String, String) {
    let asset = AVURLAsset(url: url)
    var artist = ""
    var title = ""
    for item in asset.commonMetadata {
      guard let key = item.commonKey else { continue }
      let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !value.isEmpty else { continue }
      switch key {
      case .commonKeyArtist:
        if artist.isEmpty { artist = value }
      case .commonKeyTitle:
        if title.isEmpty { title = value }
      default:
        break
      }
    }

    let (fbArtist, fbTitle) = fallbackFromPath(url)
    // Tags from folder dumps often bake in "01 Artist"; prefer a clean
    // filename parse when the tag artist still looks track-prefixed.
    if hasLeadingTrackNumber(artist), !fbArtist.isEmpty, !hasLeadingTrackNumber(fbArtist) {
      artist = fbArtist
      if title.isEmpty { title = fbTitle }
    }
    if artist.isEmpty { artist = fbArtist }
    if title.isEmpty { title = fbTitle }

    artist = stripLeadingTrackNumber(artist)
    title = stripLeadingTrackNumber(title)
    return (artist, title)
  }

  /// "01 Artist", "12. Title", "03 - Name" — keeps "3OH!3" / "2Pac".
  nonisolated static func hasLeadingTrackNumber(_ text: String) -> Bool {
    text.range(of: #"^\d{1,3}[\s.\-_]+"#, options: .regularExpression) != nil
  }

  nonisolated static func stripLeadingTrackNumber(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"^\d{1,3}[\s.\-_]+"#) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func fallbackFromPath(_ url: URL) -> (String, String) {
    var stem = stripLeadingTrackNumber(url.deletingPathExtension().lastPathComponent)

    if let sep = stem.range(of: " - ") {
      let left = String(stem[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
      let right = String(stem[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
      if !left.isEmpty, !right.isEmpty {
        return (stripLeadingTrackNumber(left), stripLeadingTrackNumber(right))
      }
    }

    let parent = url.deletingLastPathComponent().lastPathComponent
    let grand = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    let parentOK = !parent.isEmpty && Int(parent) == nil
    let grandOK = !grand.isEmpty && Int(grand) == nil
    if grandOK, parentOK {
      return (grand, stem.isEmpty ? url.lastPathComponent : stem)
    }
    if parentOK {
      return (parent, stem.isEmpty ? url.lastPathComponent : stem)
    }
    return ("Unknown Artist", stem.isEmpty ? url.lastPathComponent : stem)
  }
}

private extension String {
  var caseFolded: String { lowercased() }
}
