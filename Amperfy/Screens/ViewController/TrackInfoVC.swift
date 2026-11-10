//
//  TrackInfoVC.swift
//  Amperfy
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

import AmperfyKit
import UIKit

// MARK: - TrackInfoVC

final class TrackInfoVC: UIViewController {
  private let song: Song
  private let fileURL: URL
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let emptyLabel = UILabel()
  private var tags = AudioFileTags.empty
  private var isLoaded = false
  private var copiedFieldKey: String?
  private var lyricsCopied = false
  private var copyReset: DispatchWorkItem?

  init(song: Song, fileURL: URL) {
    self.song = song
    self.fileURL = fileURL
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Track Info"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Done",
      style: .plain,
      target: self,
      action: #selector(doneTapped)
    )
    navigationItem.largeTitleDisplayMode = .never
    view.setBackgroundBlur(style: .prominent)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 52
    tableView.sectionHeaderTopPadding = 0
    tableView.tableHeaderView = makeHeader()
    tableView.register(TrackInfoFieldCell.self, forCellReuseIdentifier: TrackInfoFieldCell.reuseID)
    tableView.register(
      TrackInfoLyricsCell.self,
      forCellReuseIdentifier: TrackInfoLyricsCell.reuseID
    )
    view.addSubview(tableView)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.text = "No tags found in this file."
    emptyLabel.font = .preferredFont(forTextStyle: .body)
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    emptyLabel.isHidden = true
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    spinner.startAnimating()
    let fileURL = fileURL
    Task.detached(priority: .userInitiated) {
      let tags = AudioFileTagReader.read(fileURL: fileURL)
      await MainActor.run { [weak self] in
        self?.apply(tags)
      }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let header = tableView.tableHeaderView else { return }
    let width = tableView.bounds.width
    let height = header.systemLayoutSizeFitting(
      CGSize(width: width, height: 0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    if header.frame.width != width || header.frame.height != height {
      header.frame.size = CGSize(width: width, height: height)
      tableView.tableHeaderView = header
    }
  }

  @objc
  private func doneTapped() {
    dismiss(animated: true)
  }

  private func apply(_ tags: AudioFileTags) {
    self.tags = tags
    isLoaded = true
    spinner.stopAnimating()
    emptyLabel.isHidden = !tags.fields.isEmpty || tags.lyrics != nil
    tableView.reloadData()
  }

  private func makeHeader() -> UIView {
    let header = UIView()
    let artwork = LibraryEntityImage(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
    artwork.translatesAutoresizingMaskIntoConstraints = false
    artwork.display(entity: song)
    artwork.clipsToBounds = true

    let titleLabel = UILabel()
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 2
    titleLabel.text = song.title

    let artistLabel = UILabel()
    artistLabel.font = .preferredFont(forTextStyle: .subheadline)
    artistLabel.textColor = .secondaryLabel
    artistLabel.numberOfLines = 1
    artistLabel.text = song.creatorName

    let fileLabel = UILabel()
    fileLabel.font = .preferredFont(forTextStyle: .footnote)
    fileLabel.textColor = .tertiaryLabel
    fileLabel.numberOfLines = 1
    fileLabel.text = fileURL.lastPathComponent
    fileLabel.lineBreakMode = .byTruncatingMiddle

    let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel, fileLabel])
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.translatesAutoresizingMaskIntoConstraints = false

    header.addSubview(artwork)
    header.addSubview(textStack)
    NSLayoutConstraint.activate([
      artwork.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
      artwork.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
      artwork.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
      artwork.widthAnchor.constraint(equalToConstant: 56),
      artwork.heightAnchor.constraint(equalToConstant: 56),
      textStack.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
      textStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
      textStack.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
    ])
    return header
  }

  private func copy(_ text: String, fieldKey: String?, lyrics: Bool) {
    UIPasteboard.general.string = text
    copiedFieldKey = fieldKey
    lyricsCopied = lyrics
    copyReset?.cancel()
    tableView.reloadData()
    let reset = DispatchWorkItem { [weak self] in
      self?.copiedFieldKey = nil
      self?.lyricsCopied = false
      self?.tableView.reloadData()
    }
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
  }

  private var showsLyrics: Bool { tags.lyrics != nil }
}

// MARK: UITableViewDataSource

extension TrackInfoVC: UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int {
    isLoaded && showsLyrics ? 2 : 1
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard isLoaded else { return 0 }
    if section == 1 { return 1 }
    return tags.fields.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == 1 {
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TrackInfoLyricsCell.reuseID,
        for: indexPath
      ) as! TrackInfoLyricsCell
      cell.display(text: tags.lyrics ?? "", copied: lyricsCopied)
      cell.onCopy = { [weak self] in
        guard let lyrics = self?.tags.lyrics else { return }
        self?.copy(lyrics, fieldKey: nil, lyrics: true)
      }
      return cell
    }
    let field = tags.fields[indexPath.row]
    let cell = tableView.dequeueReusableCell(
      withIdentifier: TrackInfoFieldCell.reuseID,
      for: indexPath
    ) as! TrackInfoFieldCell
    cell.display(name: field.name, value: field.value, copied: copiedFieldKey == field.key)
    return cell
  }
}

// MARK: UITableViewDelegate

extension TrackInfoVC: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 0, tags.fields.indices.contains(indexPath.row) else { return }
    let field = tags.fields[indexPath.row]
    copy(field.value, fieldKey: field.key, lyrics: false)
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard section == 1 else { return nil }
    let header = UIView()
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Lyrics"
    label.font = .preferredFont(forTextStyle: .headline)
    label.textColor = .label
    header.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
      label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
    ])
    return header
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == 1 ? 36 : .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    .leastNormalMagnitude
  }
}

// MARK: - TrackInfoFieldCell

private final class TrackInfoFieldCell: UITableViewCell {
  static let reuseID = "TrackInfoFieldCell"

  private let nameLabel = UILabel()
  private let valueLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectedBackgroundView = UIView()
    selectedBackgroundView?.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.12)

    nameLabel.font = .preferredFont(forTextStyle: .subheadline)
    nameLabel.textColor = .secondaryLabel
    nameLabel.numberOfLines = 2
    nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    valueLabel.font = .preferredFont(forTextStyle: .body)
    valueLabel.textColor = .label
    valueLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .firstBaseline
    stack.spacing = 16
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      nameLabel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.38),
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(name: String, value: String, copied: Bool) {
    nameLabel.text = name
    valueLabel.text = copied ? "Copied" : value
    valueLabel.textColor = copied ? .secondaryLabel : .label
    accessibilityLabel = "\(name), \(value)"
    accessibilityHint = "Copies the value"
  }
}

// MARK: - TrackInfoLyricsCell

private final class TrackInfoLyricsCell: UITableViewCell {
  static let reuseID = "TrackInfoLyricsCell"

  var onCopy: (() -> ())?
  private let lyricsLabel = UILabel()
  private let copyButton = UIButton(type: .system)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    lyricsLabel.font = .preferredFont(forTextStyle: .body)
    lyricsLabel.textColor = .label
    lyricsLabel.numberOfLines = 0
    lyricsLabel.translatesAutoresizingMaskIntoConstraints = false

    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    contentView.addSubview(lyricsLabel)
    contentView.addSubview(copyButton)
    NSLayoutConstraint.activate([
      copyButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      copyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      lyricsLabel.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 4),
      lyricsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      lyricsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      lyricsLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(text: String, copied: Bool) {
    lyricsLabel.text = text
    copyButton.setTitle(copied ? "Copied" : "Copy", for: .normal)
    copyButton.accessibilityLabel = copied ? "Copied" : "Copy lyrics"
  }

  @objc
  private func copyTapped() {
    onCopy?()
  }
}
