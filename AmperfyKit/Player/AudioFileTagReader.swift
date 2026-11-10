//
//  AudioFileTagReader.swift
//  AmperfyKit
//
//  Created by Amperfy+ on 06.11.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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

import AVFoundation
import Foundation
@preconcurrency import ID3TagEditor

// MARK: - AudioFileTagField

public struct AudioFileTagField: Sendable, Equatable {
  public let key: String
  public let name: String
  public let value: String
}

// MARK: - AudioFileTags

public struct AudioFileTags: Sendable, Equatable {
  public let fileName: String
  public let fields: [AudioFileTagField]
  public let lyrics: String?

  public static let empty = AudioFileTags(fileName: "", fields: [], lyrics: nil)
}

// MARK: - AudioFileTagReader

public enum AudioFileTagReader {
  public static func read(fileURL: URL) -> AudioFileTags {
    let fileName = fileURL.lastPathComponent
    let bag = tags(at: fileURL)
    let built = bag.build()
    return AudioFileTags(fileName: fileName, fields: built.fields, lyrics: built.lyrics)
  }

  private enum Kind {
    case flac
    case mp3
    case m4a
    case unknown
  }

  private static func tags(at fileURL: URL) -> TagBag {
    switch kind(of: fileURL) {
    case .flac:
      return readFLAC(fileURL) ?? TagBag()
    case .mp3:
      return readMP3(fileURL)
    case .m4a:
      return readM4A(fileURL)
    case .unknown:
      return TagBag()
    }
  }

  private static func kind(of fileURL: URL) -> Kind {
    let ext = fileURL.pathExtension.lowercased()
    let header = read(fileURL, offset: 0, count: 12) ?? Data()
    if ext == "flac" || header.starts(with: Data("fLaC".utf8)) {
      return .flac
    }
    if ext == "mp3" || header.starts(with: Data("ID3".utf8)) {
      return .mp3
    }
    if ["m4a", "mp4", "m4b", "aac"].contains(ext) || isFtyp(header) {
      return .m4a
    }
    return .unknown
  }

  private static func isFtyp(_ header: Data) -> Bool {
    guard header.count >= 8 else { return false }
    return header.subdata(in: 4 ..< 8) == Data("ftyp".utf8)
  }
}

// MARK: - FLAC

extension AudioFileTagReader {
  private static func readFLAC(_ fileURL: URL) -> TagBag? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
    defer { try? handle.close() }
    guard read(handle, count: 4) == Data("fLaC".utf8) else { return nil }

    var bag = TagBag()
    var isLast = false
    var consumed = 0
    let metadataLimit = 8 * 1024 * 1024
    while !isLast, consumed < metadataLimit {
      guard let header = read(handle, count: 4), header.count == 4 else { break }
      consumed += 4
      isLast = (header[0] & 0x80) != 0
      let type = header[0] & 0x7F
      let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
      guard length >= 0, consumed + length <= metadataLimit else { break }
      guard let block = read(handle, count: length), block.count == length else { break }
      consumed += length
      if type == 0 {
        if let lengthText = streamInfoLength(block), bag.values["length"] == nil {
          bag.add("length", lengthText)
        }
      } else if type == 4 {
        parseVorbisComment(block, into: &bag)
      }
    }
    return bag
  }

  private static func streamInfoLength(_ block: Data) -> String? {
    guard block.count >= 18 else { return nil }
    let packed = u64be(block, 10)
    let sampleRate = Int((packed >> 44) & 0xF_FFFF)
    let totalSamples = Int(packed & 0xF_FFFF_FFFF)
    guard sampleRate > 0, totalSamples > 0 else { return nil }
    let seconds = Int((Double(totalSamples) / Double(sampleRate)).rounded())
    guard seconds > 0 else { return nil }
    return seconds.asColonDurationString
  }

  private static func parseVorbisComment(_ block: Data, into bag: inout TagBag) {
    var offset = 0
    guard let vendorLength = u32le(block, offset) else { return }
    offset += 4 + Int(vendorLength)
    guard offset <= block.count, let count = u32le(block, offset) else { return }
    offset += 4
    for _ in 0 ..< count {
      guard offset + 4 <= block.count, let length = u32le(block, offset) else { return }
      offset += 4
      let end = offset + Int(length)
      guard end <= block.count else { return }
      let bytes = block.subdata(in: offset ..< end)
      offset = end
      guard let text = String(data: bytes, encoding: .utf8),
            let separator = text.firstIndex(of: "=")
      else { continue }
      let key = String(text[..<separator])
      let value = String(text[text.index(after: separator)...])
      if TagBag.canonicalKey(key) == "lyrics" {
        bag.addLyrics(value, synced: value.contains("["))
      } else {
        bag.add(key, value)
      }
    }
  }
}

// MARK: - MP3 / ID3

extension AudioFileTagReader {
  private static func readMP3(_ fileURL: URL) -> TagBag {
    if let bag = parseID3(fileURL), !bag.isEmpty {
      return bag
    }
    var bag = TagBag()
    mergeID3TagEditor(fileURL, into: &bag)
    return bag
  }

  private static func parseID3(_ fileURL: URL) -> TagBag? {
    guard let header = read(fileURL, offset: 0, count: 10),
          header.count == 10,
          header.starts(with: Data("ID3".utf8))
    else { return nil }
    let version = header[3]
    guard version == 2 || version == 3 || version == 4 else { return nil }
    let flags = header[5]
    let tagUnsync = (flags & 0x80) != 0
    let hasExtendedHeader = (flags & 0x40) != 0
    let tagSize = synchsafe(header, 6)
    guard tagSize > 0, tagSize < 16 * 1024 * 1024,
          var body = read(fileURL, offset: 10, count: tagSize),
          body.count == tagSize
    else { return nil }

    if hasExtendedHeader {
      let skipped = skipExtendedHeader(&body, version: version)
      guard skipped else { return TagBag() }
    }

    var bag = TagBag()
    var offset = 0
    let idLength = version == 2 ? 3 : 4
    while offset + idLength + (version == 2 ? 3 : 6) <= body.count {
      if body[offset] == 0 { break }
      let idBytes = [UInt8](body[offset ..< (offset + idLength)])
      guard idBytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else {
        break
      }
      let frameID = String(bytes: idBytes, encoding: .ascii) ?? ""
      offset += idLength
      let frameSize: Int
      if version == 2 {
        frameSize = (Int(body[offset]) << 16) | (Int(body[offset + 1]) << 8) | Int(body[offset + 2])
        offset += 3
      } else if version == 4 {
        frameSize = synchsafe(body, offset)
        offset += 4
      } else {
        frameSize = u32beInt(body, offset)
        offset += 4
      }
      var format: UInt8 = 0
      if version != 2 {
        guard offset + 2 <= body.count else { break }
        format = body[offset + 1]
        offset += 2
      }
      guard frameSize >= 0, offset + frameSize <= body.count else { break }
      let raw = body.subdata(in: offset ..< (offset + frameSize))
      offset += frameSize
      guard let payload = framePayload(
        raw,
        version: version,
        format: format,
        tagUnsync: tagUnsync
      ) else { continue }
      consumeID3Frame(frameID, payload: payload, into: &bag)
    }
    return bag
  }

  private static func skipExtendedHeader(_ body: inout Data, version: UInt8) -> Bool {
    guard body.count >= 4 else { return false }
    let size: Int
    if version == 4 {
      size = synchsafe(body, 0)
      guard size >= 4, size <= body.count else { return false }
      body.removeFirst(size)
    } else {
      size = u32beInt(body, 0)
      guard size >= 0, 4 + size <= body.count else { return false }
      body.removeFirst(4 + size)
    }
    return true
  }

  private static func framePayload(
    _ raw: Data,
    version: UInt8,
    format: UInt8,
    tagUnsync: Bool
  )
    -> Data? {
    var payload = raw
    var offset = 0
    var unsync = tagUnsync && version < 4
    if version == 4 {
      if (format & 0x08) != 0 || (format & 0x04) != 0 { return nil }
      if (format & 0x40) != 0 { offset += 1 }
      if (format & 0x01) != 0 { offset += 4 }
      unsync = unsync || (format & 0x02) != 0 || tagUnsync
    } else if version == 3 {
      if (format & 0x80) != 0 || (format & 0x40) != 0 { return nil }
      if (format & 0x20) != 0 { offset += 1 }
    }
    guard offset <= payload.count else { return nil }
    if offset > 0 {
      payload = payload.subdata(in: offset ..< payload.count)
    }
    if unsync {
      payload = unsynchronize(payload)
    }
    return payload
  }

  private static func consumeID3Frame(_ frameID: String, payload: Data, into bag: inout TagBag) {
    guard !payload.isEmpty else { return }
    switch frameID {
    case "TXX", "TXXX":
      consumeUserText(payload, into: &bag)
    case "ULT", "USLT":
      consumeLyrics(payload, synced: false, into: &bag)
    case "SLT", "SYLT":
      consumeSyncedLyrics(payload, into: &bag)
    case "COM", "COMM":
      if let text = localizedText(payload), !text.isEmpty {
        bag.add("comment", text)
      }
    case "IPLS", "TIPL":
      consumeInvolvedPeople(payload, into: &bag)
    default:
      guard frameID.hasPrefix("T"), let text = plainText(payload) else { return }
      let key = frameKeys[frameID] ?? frameID
      for value in text.split(separator: "\n").map(String.init) where !value.isEmpty {
        bag.add(key, value)
      }
    }
  }

  private static let frameKeys = [
    "TIT2": "title", "TT2": "title",
    "TPE1": "artist", "TP1": "artist",
    "TALB": "album", "TAL": "album",
    "TRCK": "tracknumber", "TRK": "tracknumber",
    "TLEN": "length",
    "TDRC": "date", "TYER": "date", "TYE": "date", "TDRL": "date",
    "TPE2": "albumartist", "TP2": "albumartist",
    "TSO2": "albumartistsort",
    "TSOP": "artistsort",
    "TSOA": "albumsort",
    "TSOT": "titlesort",
    "TPOS": "discnumber", "TPA": "discnumber",
    "TLAN": "language",
    "TCON": "genre", "TCO": "genre",
    "TCOM": "composer", "TCM": "composer",
    "TIT1": "grouping",
    "TIT3": "subtitle",
    "TPE3": "conductor",
    "TPE4": "remixer",
    "TCOP": "copyright",
    "TPUB": "publisher",
    "TSRC": "isrc",
    "TBPM": "bpm",
  ]

  private static func consumeUserText(_ payload: Data, into bag: inout TagBag) {
    guard let encoding = payload.first else { return }
    var offset = 1
    let description = readTerminated(&offset, payload, encoding: encoding)
    let value = remainingText(payload, offset: offset, encoding: encoding)
    guard !value.isEmpty else { return }
    let key = description.isEmpty ? "comment" : description
    if TagBag.canonicalKey(key) == "lyrics" {
      bag.addLyrics(value, synced: value.contains("["))
    } else {
      bag.add(key, value)
    }
  }

  private static func consumeLyrics(_ payload: Data, synced: Bool, into bag: inout TagBag) {
    guard payload.count > 4, let text = localizedText(payload), !text.isEmpty else { return }
    let lang = languageCode(payload)
    bag.addLyrics(text, synced: synced)
    rememberLanguage(lang, into: &bag)
  }

  private static func consumeSyncedLyrics(_ payload: Data, into bag: inout TagBag) {
    guard payload.count > 6 else { return }
    let encoding = payload[0]
    let format = payload[4]
    var offset = 6
    _ = readTerminated(&offset, payload, encoding: encoding)
    var lines: [String] = []
    while offset < payload.count {
      let text = readTerminated(&offset, payload, encoding: encoding)
      guard offset + 4 <= payload.count else { break }
      let timestamp = Int(u32be(payload, offset))
      offset += 4
      guard !text.isEmpty else { continue }
      if format == 2 {
        lines.append(lrc(milliseconds: timestamp, text: text))
      } else {
        lines.append(text)
      }
    }
    guard !lines.isEmpty else { return }
    bag.addLyrics(lines.joined(separator: "\n"), synced: true)
    rememberLanguage(languageCode(payload), into: &bag)
  }

  private static func consumeInvolvedPeople(_ payload: Data, into bag: inout TagBag) {
    guard let encoding = payload.first else { return }
    var offset = 1
    var parts: [String] = []
    while offset < payload.count {
      let part = readTerminated(&offset, payload, encoding: encoding)
      if !part.isEmpty { parts.append(part) }
    }
    var index = 0
    while index + 1 < parts.count {
      bag.add(parts[index], parts[index + 1])
      index += 2
    }
  }

  private static func localizedText(_ payload: Data) -> String? {
    guard payload.count > 4 else { return nil }
    let encoding = payload[0]
    var offset = 4
    _ = readTerminated(&offset, payload, encoding: encoding)
    let text = remainingText(payload, offset: offset, encoding: encoding)
    return text.isEmpty ? nil : text
  }

  private static func languageCode(_ payload: Data) -> String {
    guard payload.count >= 4 else { return "" }
    return String(bytes: payload[1 ..< 4], encoding: .ascii)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func rememberLanguage(_ lang: String, into bag: inout TagBag) {
    let folded = lang.lowercased()
    guard !folded.isEmpty, folded != "xxx", bag.values["language"] == nil else { return }
    bag.add("language", folded)
  }

  private static func plainText(_ payload: Data) -> String? {
    guard let encoding = payload.first else { return nil }
    let text = remainingText(payload, offset: 1, encoding: encoding)
    guard !text.isEmpty else { return nil }
    return cleanupGenre(text)
  }

  private static func remainingText(_ payload: Data, offset: Int, encoding: UInt8) -> String {
    var cursor = offset
    var parts: [String] = []
    while cursor < payload.count {
      let part = readTerminated(&cursor, payload, encoding: encoding)
      if !part.isEmpty { parts.append(part) }
    }
    return parts.joined(separator: "\n")
  }

  private static func readTerminated(
    _ offset: inout Int,
    _ data: Data,
    encoding: UInt8
  )
    -> String {
    guard offset < data.count else { return "" }
    let start = offset
    if encoding == 1 || encoding == 2 {
      var index = offset
      if (index - start) % 2 != 0 { index += 1 }
      while index + 1 < data.count {
        if data[index] == 0, data[index + 1] == 0 {
          let slice = data.subdata(in: start ..< index)
          offset = index + 2
          return decode(slice, encoding: encoding)
        }
        index += 2
      }
      let slice = data.subdata(in: start ..< data.count)
      offset = data.count
      return decode(slice, encoding: encoding)
    }
    var index = offset
    while index < data.count, data[index] != 0 {
      index += 1
    }
    let slice = data.subdata(in: start ..< index)
    offset = min(data.count, index + 1)
    return decode(slice, encoding: encoding == 3 ? 3 : 0)
  }

  private static func decode(_ data: Data, encoding: UInt8) -> String {
    let stringEncoding: String.Encoding = switch encoding {
    case 1: .utf16
    case 2: .utf16BigEndian
    case 3: .utf8
    default: .isoLatin1
    }
    return String(data: data, encoding: stringEncoding)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func cleanupGenre(_ text: String) -> String {
    guard text.hasPrefix("("), let end = text.firstIndex(of: ")") else { return text }
    let remainder = text[text.index(after: end)...].trimmingCharacters(in: .whitespaces)
    return remainder.isEmpty ? text : remainder
  }

  private static func lrc(milliseconds: Int, text: String) -> String {
    let clamped = max(0, milliseconds)
    let minutes = clamped / 60_000
    let seconds = (clamped % 60_000) / 1000
    let millis = clamped % 1000
    return String(format: "[%02d:%02d.%03d]%@", minutes, seconds, millis, text)
  }

  private static func unsynchronize(_ data: Data) -> Data {
    var output = Data()
    output.reserveCapacity(data.count)
    var index = 0
    while index < data.count {
      output.append(data[index])
      if data[index] == 0xFF, index + 1 < data.count, data[index + 1] == 0 {
        index += 2
      } else {
        index += 1
      }
    }
    return output
  }

  private static func mergeID3TagEditor(_ fileURL: URL, into bag: inout TagBag) {
    guard let tag = try? ID3TagEditor().read(from: fileURL.path) else { return }
    let reader = ID3TagContentReader(id3Tag: tag)
    addIfMissing("title", reader.title(), to: &bag)
    addIfMissing("artist", reader.artist(), to: &bag)
    addIfMissing("album", reader.album(), to: &bag)
    addIfMissing("albumartist", reader.albumArtist(), to: &bag)
    addIfMissing("composer", reader.composer(), to: &bag)
    addIfMissing("conductor", reader.conductor(), to: &bag)
    addIfMissing("subtitle", reader.subtitle(), to: &bag)
    addIfMissing("publisher", reader.publisher(), to: &bag)
    addIfMissing("copyright", reader.copyright(), to: &bag)
    if let genre = reader.genre()?.description, !genre.isEmpty {
      addIfMissing("genre", genre, to: &bag)
    }
    if let track = reader.trackPosition() {
      addIfMissing("tracknumber", partOfTotal(track.position, track.total), to: &bag)
    }
    if let disc = reader.discPosition() {
      addIfMissing("discnumber", partOfTotal(disc.position, disc.total), to: &bag)
    }
    if let date = recordingDate(reader) {
      addIfMissing("date", date, to: &bag)
    }
    if let length = reader.lengthInMilliseconds(), length > 0 {
      addIfMissing("length", (length / 1000).asColonDurationString, to: &bag)
    }
    if bag.resolvedLyrics() == nil {
      let lyrics = reader.unsynchronizedLyrics().map(\.content).filter { !$0.isEmpty }
      if !lyrics.isEmpty {
        bag.addLyrics(lyrics.joined(separator: "\n"), synced: false)
      }
    }
  }

  private static func addIfMissing(_ key: String, _ value: String?, to bag: inout TagBag) {
    guard bag.values[key] == nil, let value, !value.isEmpty else { return }
    bag.add(key, value)
  }

  private static func partOfTotal(_ position: Int, _ total: Int?) -> String {
    if let total, total > 0 {
      return "\(position)/\(total)"
    }
    return "\(position)"
  }

  private static func recordingDate(_ reader: ID3TagContentReader) -> String? {
    if let date = reader.recordingDateTime(), let year = date.year {
      if let month = date.month, let day = date.day {
        return String(format: "%04d-%02d-%02d", year, month, day)
      }
      return String(year)
    }
    if let year = reader.recordingYear() {
      return String(year)
    }
    return nil
  }
}

// MARK: - M4A

extension AudioFileTagReader {
  private static func readM4A(_ fileURL: URL) -> TagBag {
    let asset = AVURLAsset(url: fileURL)
    var bag = TagBag()
    let seconds = CMTimeGetSeconds(asset.duration)
    if seconds.isFinite, seconds > 0 {
      bag.add("length", Int(seconds.rounded()).asColonDurationString)
    }
    for item in asset.metadata {
      guard let key = m4aKey(item) else { continue }
      if let text = m4aText(item, key: key), !text.isEmpty {
        if key == "lyrics" {
          bag.addLyrics(text, synced: text.contains("["))
        } else {
          bag.add(key, text)
        }
      }
    }
    return bag
  }

  private static func m4aKey(_ item: AVMetadataItem) -> String? {
    if let identifier = item.identifier {
      switch identifier {
      case .commonIdentifierTitle, .iTunesMetadataSongName:
        return "title"
      case .commonIdentifierArtist, .iTunesMetadataArtist:
        return "artist"
      case .commonIdentifierAlbumName, .iTunesMetadataAlbum:
        return "album"
      case .commonIdentifierCreationDate, .iTunesMetadataReleaseDate:
        return "date"
      case .iTunesMetadataAlbumArtist:
        return "albumartist"
      case .iTunesMetadataLyrics:
        return "lyrics"
      case .commonIdentifierType, .iTunesMetadataPredefinedGenre, .iTunesMetadataUserGenre:
        return "genre"
      case .iTunesMetadataTrackNumber:
        return "tracknumber"
      case .iTunesMetadataDiscNumber:
        return "discnumber"
      case .iTunesMetadataUserComment:
        return "comment"
      default:
        let raw = identifier.rawValue.lowercased()
        if raw.contains("covr") || raw.contains("artwork") || raw.contains("data") {
          return nil
        }
        return nil
      }
    }
    return nil
  }

  private static func m4aText(_ item: AVMetadataItem, key: String) -> String? {
    if let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text
    }
    if let number = item.numberValue {
      return number.stringValue
    }
    if let date = item.dateValue {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.string(from: date)
    }
    guard let data = item.dataValue, data.count >= 4,
          key == "tracknumber" || key == "discnumber"
    else { return nil }
    let number: Int
    let total: Int
    if data.count >= 8 {
      number = (Int(data[2]) << 8) | Int(data[3])
      total = (Int(data[4]) << 8) | Int(data[5])
    } else {
      number = (Int(data[2]) << 8) | Int(data[3])
      total = 0
    }
    guard number > 0 else { return nil }
    return partOfTotal(number, total > 0 ? total : nil)
  }
}

// MARK: AudioFileTagReader.TagBag

extension AudioFileTagReader {
  struct TagBag {
    var values: [String: [String]] = [:]
    var lyrics: [String] = []
    var syncedLyrics: [String] = []

    var isEmpty: Bool {
      values.isEmpty && lyrics.isEmpty && syncedLyrics.isEmpty
    }

    mutating func add(_ key: String, _ value: String) {
      let canonical = Self.canonicalKey(key)
      guard canonical != "lyrics" else {
        addLyrics(value, synced: value.contains("["))
        return
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      if canonical == "length", values["length"] != nil { return }
      var existing = values[canonical] ?? []
      if !existing.contains(trimmed) {
        existing.append(trimmed)
      }
      values[canonical] = existing
    }

    mutating func addLyrics(_ text: String, synced: Bool) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      if synced {
        if !syncedLyrics.contains(trimmed) { syncedLyrics.append(trimmed) }
      } else if !lyrics.contains(trimmed) {
        lyrics.append(trimmed)
      }
    }

    func resolvedLyrics() -> String? {
      let source = syncedLyrics.isEmpty ? lyrics : syncedLyrics
      let text = source.joined(separator: "\n")
      return text.isEmpty ? nil : text
    }

    func build() -> (fields: [AudioFileTagField], lyrics: String?) {
      var fields: [AudioFileTagField] = []
      var used = Set<String>()
      for key in Self.preferredOrder {
        guard let parts = values[key], !parts.isEmpty else { continue }
        used.insert(key)
        fields.append(AudioFileTagField(
          key: key,
          name: Self.displayName(for: key),
          value: key == "length" ? Self.formatLength(parts.joined(separator: "\n")) : parts
            .joined(separator: "\n")
        ))
      }
      let extras = values.keys.filter { !used.contains($0) }.sorted()
      for key in extras {
        guard let parts = values[key], !parts.isEmpty else { continue }
        fields.append(AudioFileTagField(
          key: key,
          name: Self.displayName(for: key),
          value: parts.joined(separator: "\n")
        ))
      }
      return (fields, resolvedLyrics())
    }

    static let preferredOrder = [
      "title",
      "artist",
      "album",
      "tracknumber",
      "length",
      "date",
      "albumartist",
      "albumartistsort",
      "albumartists",
      "arranger",
      "musicbrainz_artistid",
      "artistsort",
      "artists",
      "barcode",
      "catalognumber",
      "discnumber",
      "language",
    ]

    static let displayNames = [
      "title": "Title",
      "artist": "Artist",
      "album": "Album",
      "tracknumber": "Track Number",
      "length": "Length",
      "date": "Date",
      "albumartist": "Album Artist",
      "albumartistsort": "Album Artist Sort Order",
      "albumartists": "Album Artists",
      "arranger": "Arranger",
      "musicbrainz_artistid": "Artist MBID",
      "artistsort": "Artist Sort Order",
      "artists": "Artists",
      "barcode": "Barcode",
      "catalognumber": "Catalog Number",
      "discnumber": "Disc Number",
      "language": "Language",
      "lyrics": "Lyrics",
      "genre": "Genre",
      "composer": "Composer",
      "isrc": "ISRC",
      "comment": "Comment",
      "bpm": "BPM",
      "albumsort": "Album Sort",
      "titlesort": "Title Sort",
      "grouping": "Grouping",
      "subtitle": "Subtitle",
      "conductor": "Conductor",
      "remixer": "Remixer",
      "copyright": "Copyright",
      "publisher": "Publisher",
    ]

    static func canonicalKey(_ raw: String) -> String {
      let folded = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
      let aliases = [
        "title": "title",
        "artist": "artist",
        "album": "album",
        "track": "tracknumber",
        "tracknumber": "tracknumber",
        "trackno": "tracknumber",
        "length": "length",
        "date": "date",
        "year": "date",
        "albumartist": "albumartist",
        "albumartistsort": "albumartistsort",
        "albumartists": "albumartists",
        "arranger": "arranger",
        "musicbrainzartistid": "musicbrainz_artistid",
        "artistsort": "artistsort",
        "artists": "artists",
        "barcode": "barcode",
        "catalognumber": "catalognumber",
        "disc": "discnumber",
        "discnumber": "discnumber",
        "disk": "discnumber",
        "disknumber": "discnumber",
        "language": "language",
        "lyrics": "lyrics",
        "unsyncedlyrics": "lyrics",
        "syncedlyrics": "lyrics",
        "genre": "genre",
        "composer": "composer",
        "isrc": "isrc",
        "comment": "comment",
        "bpm": "bpm",
      ]
      if let known = aliases[folded] { return known }
      let words = raw.lowercased().split { !$0.isLetter && !$0.isNumber }
      return words.joined(separator: "_")
    }

    static func displayName(for key: String) -> String {
      if let name = displayNames[key] { return name }
      if key.count <= 4, key.allSatisfy(\.isLetter) || key.allSatisfy(\.isNumber) {
        return key.uppercased()
      }
      return key.split(separator: "_").map { word in
        guard let first = word.first else { return "" }
        return first.uppercased() + word.dropFirst()
      }.joined(separator: " ")
    }

    static func formatLength(_ raw: String) -> String {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.contains(":") { return trimmed }
      guard let number = Int(trimmed) else { return trimmed }
      let seconds = number >= 1000 ? number / 1000 : number
      guard seconds > 0 else { return trimmed }
      return seconds.asColonDurationString
    }
  }
}

// MARK: - Binary helpers

extension AudioFileTagReader {
  private static func read(_ fileURL: URL, offset: Int, count: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: UInt64(offset))
      return try handle.read(upToCount: count)
    } catch {
      return nil
    }
  }

  private static func read(_ handle: FileHandle, count: Int) -> Data? {
    guard count > 0 else { return Data() }
    return try? handle.read(upToCount: count)
  }

  private static func synchsafe(_ data: Data, _ offset: Int) -> Int {
    guard offset + 4 <= data.count else { return 0 }
    return (Int(data[offset]) << 21) |
      (Int(data[offset + 1]) << 14) |
      (Int(data[offset + 2]) << 7) |
      Int(data[offset + 3])
  }

  private static func u32be(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return (UInt32(data[offset]) << 24) |
      (UInt32(data[offset + 1]) << 16) |
      (UInt32(data[offset + 2]) << 8) |
      UInt32(data[offset + 3])
  }

  private static func u32beInt(_ data: Data, _ offset: Int) -> Int {
    Int(u32be(data, offset))
  }

  private static func u32le(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }

  private static func u64be(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    var value: UInt64 = 0
    for index in 0 ..< 8 {
      value = (value << 8) | UInt64(data[offset + index])
    }
    return value
  }
}
