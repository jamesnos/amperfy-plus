//
//  AudioFileTagReaderTest.swift
//  AmperfyKitTests
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

@testable import AmperfyKit
import XCTest

class AudioFileTagReaderTest: XCTestCase {
  func testFLACVorbisCommentsAndStreamInfoLength() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("father-figure-\(UUID().uuidString).flac")
    try flacFixture().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let tags = AudioFileTagReader.read(fileURL: url)
    XCTAssertEqual(tags.fields.map(\.name), [
      "Title",
      "Artist",
      "Album",
      "Track Number",
      "Length",
      "Artist MBID",
      "Barcode",
    ])
    XCTAssertEqual(value("Title", tags), "Father Figure")
    XCTAssertEqual(value("Artist", tags), "Taylor Swift")
    XCTAssertEqual(value("Album", tags), "The Life of a Showgirl")
    XCTAssertEqual(value("Track Number", tags), "4")
    XCTAssertEqual(value("Length", tags), "3:33")
    XCTAssertEqual(value("Barcode", tags), "602478225321")
    XCTAssertEqual(
      value("Artist MBID", tags),
      "20244d07-534f-4eff-b4d4-930878889970"
    )
    XCTAssertEqual(tags.lyrics, "[00:06.141]When I found you")
  }

  func testID3TextFramesUserTextAndSyncedLyrics() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("father-figure-\(UUID().uuidString).mp3")
    try id3Fixture().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let tags = AudioFileTagReader.read(fileURL: url)
    XCTAssertEqual(value("Title", tags), "Father Figure")
    XCTAssertEqual(value("Artist", tags), "Taylor Swift")
    XCTAssertEqual(value("Arranger", tags), "Mattias Bylund")
    XCTAssertEqual(value("Barcode", tags), "602478225321")
    XCTAssertEqual(value("Catalog Number", tags), "00602478225321")
    XCTAssertEqual(tags.lyrics, "[00:06.141]When I found you")
    XCTAssertEqual(value("Language", tags), "eng")
  }

  private func value(_ name: String, _ tags: AudioFileTags) -> String? {
    tags.fields.first { $0.name == name }?.value
  }

  private func flacFixture() -> Data {
    var data = Data("fLaC".utf8)
    data.append(streamInfoBlock(isLast: false))
    data.append(vorbisBlock(isLast: true, comments: [
      "TITLE=Father Figure",
      "ARTIST=Taylor Swift",
      "ALBUM=The Life of a Showgirl",
      "TRACKNUMBER=4",
      "BARCODE=602478225321",
      "MUSICBRAINZ_ARTISTID=20244d07-534f-4eff-b4d4-930878889970",
      "LYRICS=[00:06.141]When I found you",
    ]))
    return data
  }

  private func streamInfoBlock(isLast: Bool) -> Data {
    var block = Data([isLast ? 0x80 : 0x00, 0x00, 0x00, 34])
    var info = Data(count: 34)
    let sampleRate: UInt64 = 44_100
    let totalSamples: UInt64 = 44_100 * 213
    let packed = (sampleRate << 44) | (1 << 41) | (15 << 36) | totalSamples
    for index in 0 ..< 8 {
      info[10 + index] = UInt8((packed >> (56 - (index * 8))) & 0xFF)
    }
    block.append(info)
    return block
  }

  private func vorbisBlock(isLast: Bool, comments: [String]) -> Data {
    var payload = Data(count: 4)
    var count = UInt32(comments.count).littleEndian
    payload.append(Data(bytes: &count, count: 4))
    for comment in comments {
      var length = UInt32(comment.utf8.count).littleEndian
      payload.append(Data(bytes: &length, count: 4))
      payload.append(contentsOf: comment.utf8)
    }
    var header = Data([isLast ? 0x84 : 0x04])
    header.append(UInt8((payload.count >> 16) & 0xFF))
    header.append(UInt8((payload.count >> 8) & 0xFF))
    header.append(UInt8(payload.count & 0xFF))
    header.append(payload)
    return header
  }

  private func id3Fixture() -> Data {
    let frames = textFrame("TIT2", "Father Figure") +
      textFrame("TPE1", "Taylor Swift") +
      userTextFrame("BARCODE", "602478225321") +
      userTextFrame("CATALOGNUMBER", "00602478225321") +
      involvedPeopleFrame() +
      syncedLyricsFrame()
    var header = Data("ID3".utf8)
    header.append(contentsOf: [3, 0, 0])
    header.append(contentsOf: synchsafe(frames.count))
    header.append(frames)
    return header
  }

  private func textFrame(_ id: String, _ value: String) -> Data {
    var content = Data([3])
    content.append(contentsOf: value.utf8)
    return frame(id, content)
  }

  private func userTextFrame(_ description: String, _ value: String) -> Data {
    var content = Data([3])
    content.append(contentsOf: description.utf8)
    content.append(0)
    content.append(contentsOf: value.utf8)
    return frame("TXXX", content)
  }

  private func involvedPeopleFrame() -> Data {
    var content = Data([3])
    content.append(contentsOf: "Arranger".utf8)
    content.append(0)
    content.append(contentsOf: "Mattias Bylund".utf8)
    content.append(0)
    return frame("TIPL", content)
  }

  private func syncedLyricsFrame() -> Data {
    var content = Data([3])
    content.append(contentsOf: "eng".utf8)
    content.append(2)
    content.append(1)
    content.append(0)
    content.append(contentsOf: "When I found you".utf8)
    content.append(0)
    var timestamp = UInt32(6141).bigEndian
    content.append(Data(bytes: &timestamp, count: 4))
    return frame("SYLT", content)
  }

  private func frame(_ id: String, _ content: Data) -> Data {
    var data = Data(id.utf8)
    var size = UInt32(content.count).bigEndian
    data.append(Data(bytes: &size, count: 4))
    data.append(contentsOf: [0, 0])
    data.append(content)
    return data
  }

  private func synchsafe(_ size: Int) -> [UInt8] {
    [
      UInt8((size >> 21) & 0x7F),
      UInt8((size >> 14) & 0x7F),
      UInt8((size >> 7) & 0x7F),
      UInt8(size & 0x7F),
    ]
  }
}
