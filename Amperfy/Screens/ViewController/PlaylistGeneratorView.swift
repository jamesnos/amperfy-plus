//
//  PlaylistGeneratorView.swift
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
import SwiftUI
import UIKit

// MARK: - PlaylistGeneratorHostVC

/// Hosts the generator as the navigation content so toolbar items land in the nav bar,
/// and applies the same mini-player safe area as the library screens.
final class PlaylistGeneratorHostVC: UIHostingController<PlaylistGeneratorView> {
  private let toolbar: PlaylistGeneratorToolbar

  init(account: Account) {
    let toolbar = PlaylistGeneratorToolbar()
    self.toolbar = toolbar
    super.init(rootView: PlaylistGeneratorView(account: account, toolbar: toolbar))
    toolbar.host = self
    title = "Playlist Generator"
    view.backgroundColor = .systemBackground
  }

  func applyToolbar(_ state: PlaylistGeneratorToolbarState) {
    let match = UIBarButtonItem(
      title: state.matchTitle,
      style: .plain,
      target: toolbar,
      action: #selector(PlaylistGeneratorToolbar.matchTapped)
    )
    match.isEnabled = state.matchEnabled
    let create = UIBarButtonItem(
      title: state.createTitle,
      style: .plain,
      target: toolbar,
      action: #selector(PlaylistGeneratorToolbar.createTapped)
    )
    create.isEnabled = state.createEnabled
    navigationItem.rightBarButtonItems = [create, match]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let hostVC = AppDelegate.mainWindowHostVC else { return }
    let bottom = hostVC.getSafeAreaExtension()
    if additionalSafeAreaInsets.bottom != bottom {
      extendSafeAreaToAccountForMiniPlayer()
    }
  }
}

// MARK: - PlaylistGeneratorToolbarState

struct PlaylistGeneratorToolbarState: Equatable {
  var matchTitle: String
  var matchEnabled: Bool
  var createTitle: String
  var createEnabled: Bool
}

// MARK: - PlaylistGeneratorToolbar

final class PlaylistGeneratorToolbar: NSObject {
  weak var host: PlaylistGeneratorHostVC?
  var matchAction: () -> () = {}
  var createAction: () -> () = {}

  func apply(_ state: PlaylistGeneratorToolbarState) {
    host?.applyToolbar(state)
  }

  @objc
  func matchTapped() {
    matchAction()
  }

  @objc
  func createTapped() {
    createAction()
  }
}

// MARK: - MatchTableLayout

private enum MatchTableLayout {
  static let margin: CGFloat = 20
  static let unit: CGFloat = 8
  static let artwork: CGFloat = 40
  static let rowHeight: CGFloat = 60
  static let indexWidth: CGFloat = 28
  static let columnSpacing: CGFloat = 16
  static let requestedFraction: CGFloat = 0.38
  /// System list reorder control, so the header lines up with the row columns.
  static let reorderControlWidth: CGFloat = 36
  /// Trash control sitting immediately before the reorder grip.
  static let deleteButtonWidth: CGFloat = 36
  /// Caption, spacing, and vertical padding around the empty-state paste box.
  static let emptyInputChrome: CGFloat = 64
}

// MARK: - MatchColumns

private struct MatchColumns {
  let requested: CGFloat
  let match: CGFloat

  static func resolve(containerWidth: CGFloat) -> MatchColumns {
    let trailingControls = MatchTableLayout.reorderControlWidth + MatchTableLayout.deleteButtonWidth
    let inner = containerWidth - (MatchTableLayout.margin * 2) - trailingControls
    let gaps = MatchTableLayout.columnSpacing * 2
    let flexible = max(0, inner - MatchTableLayout.indexWidth - gaps)
    let requested = flexible * MatchTableLayout.requestedFraction
    return MatchColumns(requested: requested, match: flexible - requested)
  }
}

// MARK: - PlaylistGeneratorView

struct PlaylistGeneratorView: View {
  @StateObject
  private var model: PlaylistGeneratorModel
  @State
  private var showNamePrompt = false
  @State
  private var pendingPlaylistName = ""
  @State
  private var createError: String?
  private let toolbar: PlaylistGeneratorToolbar

  init(account: Account, toolbar: PlaylistGeneratorToolbar) {
    _model = StateObject(wrappedValue: PlaylistGeneratorModel(account: account))
    self.toolbar = toolbar
  }

  var body: some View {
    GeometryReader { proxy in
      let columns = MatchColumns.resolve(containerWidth: proxy.size.width)
      let statusChrome: CGFloat = model.rows.isEmpty && !model.statusMessage.isEmpty ? 28 : 0
      let editorHeight = max(
        96,
        proxy.size.height - MatchTableLayout.emptyInputChrome - statusChrome
      )
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: MatchTableLayout.unit) {
          inputSection(editorHeight: editorHeight)
          if !model.rows.isEmpty {
            matchSummary
            columnHeader(columns)
          } else if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .padding(.horizontal, MatchTableLayout.margin)
        .padding(.top, MatchTableLayout.unit / 2)
        .padding(.bottom, model.rows.isEmpty ? MatchTableLayout.margin : MatchTableLayout.unit / 2)
        .frame(
          maxWidth: .infinity,
          maxHeight: model.rows.isEmpty ? .infinity : nil,
          alignment: .top
        )

        if !model.rows.isEmpty {
          List {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
              PlaylistMatchListRow(
                index: index + 1,
                row: row,
                columns: columns,
                onOpen: { model.openReview(for: row.id) },
                onDelete: { model.deleteRow(id: row.id) }
              )
              .listRowInsets(
                EdgeInsets(
                  top: 0,
                  leading: MatchTableLayout.margin,
                  bottom: 0,
                  trailing: MatchTableLayout.margin
                )
              )
              .listRowSeparator(.visible, edges: .bottom)
            }
            .onMove(perform: model.moveRows)
            PlaylistAddTrackRow(isEnabled: !model.isMatching) { line in
              await model.addTrack(line: line)
            }
            .listRowInsets(
              EdgeInsets(
                top: 0,
                leading: MatchTableLayout.margin,
                bottom: 0,
                trailing: MatchTableLayout.margin
              )
            )
            .listRowSeparator(.hidden)
          }
          .listStyle(.plain)
          .listRowSpacing(0)
          .environment(\.editMode, .constant(.active))
          .environment(\.defaultMinListRowHeight, MatchTableLayout.rowHeight)
          .modifier(ScrollContentMarginsZeroModifier())
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }
    }
    .navigationTitle("Playlist Generator")
    .onAppear { syncToolbar() }
    .onChange(of: toolbarState) { _ in syncToolbar() }
    .sheet(isPresented: Binding(
      get: { model.reviewingRowID != nil },
      set: { if !$0 { model.closeReview() } }
    )) {
      PlaylistMatchPickerSheet(model: model, themeColor: accountThemeColor)
    }
    .sheet(isPresented: $showNamePrompt) {
      PlaylistNameSheet(
        name: $pendingPlaylistName,
        matchedCount: model.matchedCount,
        excludedCount: max(model.rows.count - model.matchedCount, 0),
        themeColor: accountThemeColor,
        isCreating: model.isCreating,
        errorMessage: createError,
        onCancel: {
          pendingPlaylistName = ""
          createError = nil
          showNamePrompt = false
        },
        onCreate: {
          let name = pendingPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty, !model.isCreating else { return }
          createError = nil
          Task {
            model.playlistName = name
            switch await model.createPlaylist() {
            case let .success(playlist):
              showNamePrompt = false
              createError = nil
              showCreatedPlaylist(playlist)
            case let .failure(message):
              createError = message
            }
          }
        }
      )
    }
  }

  private func showCreatedPlaylist(_ playlist: Playlist) {
    let detail = AppStoryboard.Main.segueToPlaylistDetail(
      account: model.account,
      playlist: playlist
    )
    guard let root = AppDelegate.mainSceneDelegate?.window?.rootViewController,
          let navigation = Self.navigationController(
            in: root,
            containing: PlaylistGeneratorHostVC.self
          )
    else { return }
    navigation.pushViewController(detail, animated: true)
  }

  private static func navigationController(
    in viewController: UIViewController,
    containing type: UIViewController.Type
  )
    -> UINavigationController? {
    if let navigation = viewController as? UINavigationController {
      if navigation.viewControllers.contains(where: { $0.isKind(of: type) }) {
        return navigation
      }
      for child in navigation.viewControllers {
        if let found = navigationController(in: child, containing: type) {
          return found
        }
      }
    }
    if viewController.isKind(of: type) {
      return viewController.navigationController
    }
    for child in viewController.children {
      if let found = navigationController(in: child, containing: type) {
        return found
      }
    }
    if let presented = viewController.presentedViewController,
       let found = navigationController(in: presented, containing: type) {
      return found
    }
    return nil
  }

  private var toolbarState: PlaylistGeneratorToolbarState {
    PlaylistGeneratorToolbarState(
      matchTitle: matchButtonTitle,
      matchEnabled: !matchButtonDisabled,
      createTitle: createButtonTitle,
      createEnabled: model.canCreate
    )
  }

  private func syncToolbar() {
    let model = model
    toolbar.matchAction = {
      if model.isMatching {
        model.cancelMatch()
      } else {
        model.startMatch()
      }
    }
    toolbar.createAction = {
      pendingPlaylistName = model.playlistName
      createError = nil
      showNamePrompt = true
    }
    toolbar.apply(toolbarState)
  }

  private var matchButtonTitle: String {
    if model.isMatching { return "Cancel" }
    return model.rows.isEmpty ? "Match" : "Match Again"
  }

  private var matchButtonDisabled: Bool {
    !model.isMatching && model.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var matchButtonAction: () -> () {
    model.isMatching ? model.cancelMatch : model.startMatch
  }

  private var createButtonTitle: String {
    model.matchedCount > 0 ? "Create Playlist (\(model.matchedCount))" : "Create Playlist"
  }

  private var accountThemeColor: Color {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
      return ThemePreference.defaultValue.asSwiftUIColor
    }
    let settings = appDelegate.storage.settings.accounts
    guard let active = settings.active else { return ThemePreference.defaultValue.asSwiftUIColor }
    return settings.getSetting(active).read.themePreference.asSwiftUIColor
  }

  private func inputSection(editorHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: MatchTableLayout.unit) {
      if model.inputExpanded || model.rows.isEmpty {
        Text("One song per line: Artist - Title")
          .font(.body)
          .foregroundStyle(.secondary)
        songInput(editorHeight: editorHeight)
          .disabled(model.isMatching)
          .accessibilityLabel("Songs to match")
      } else {
        Text(importedSummary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if model.isMatching {
        HStack(spacing: MatchTableLayout.unit) {
          ProgressView()
            .controlSize(.small)
          Text(model.progressText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func songInput(editorHeight: CGFloat) -> some View {
    let editor = TextEditor(text: $model.pasteText)
      .font(.body)
    return Group {
      if model.rows.isEmpty {
        editor
          .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity)
          .frame(height: editorHeight)
          .overlay(inputBorder)
      } else {
        editor
          .frame(minHeight: 96, maxHeight: 160)
          .overlay(inputBorder)
      }
    }
  }

  private var inputBorder: some View {
    RoundedRectangle(cornerRadius: 6)
      .stroke(Color.secondary.opacity(0.35))
  }

  private var importedSummary: String {
    let count = model.rows.count
    return "\(count) \(count == 1 ? "song" : "songs") imported"
  }

  private var matchSummary: some View {
    HStack(spacing: MatchTableLayout.columnSpacing) {
      summaryItem(
        count: model.matchedCount,
        singular: "matched",
        plural: "matched",
        symbol: "checkmark.circle.fill",
        color: .green
      )
      summaryItem(
        count: model.reviewCount,
        singular: "needs review",
        plural: "need review",
        symbol: "exclamationmark.triangle.fill",
        color: .orange
      )
      summaryItem(
        count: model.missingCount,
        singular: "missing",
        plural: "missing",
        symbol: "xmark.circle.fill",
        color: .secondary
      )
      Spacer(minLength: MatchTableLayout.unit)
      if !model.statusMessage.isEmpty {
        Text(model.statusMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .font(.subheadline)
    .accessibilityElement(children: .combine)
  }

  private func summaryItem(
    count: Int,
    singular: String,
    plural: String,
    symbol: String,
    color: Color
  )
    -> some View {
    Label("\(count) \(count == 1 ? singular : plural)", systemImage: symbol)
      .foregroundStyle(color)
      .lineLimit(1)
  }

  private func columnHeader(_ columns: MatchColumns) -> some View {
    HStack(spacing: MatchTableLayout.columnSpacing) {
      Text("#")
        .frame(width: MatchTableLayout.indexWidth, alignment: .trailing)
      Text("Requested Song")
        .frame(width: columns.requested, alignment: .leading)
      Text("Library Match")
        .frame(width: columns.match, alignment: .leading)
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .padding(.trailing, MatchTableLayout.reorderControlWidth + MatchTableLayout.deleteButtonWidth)
  }
}

// MARK: - PlaylistMatchListRow

private struct PlaylistMatchListRow: View {
  let index: Int
  let row: PlaylistMatchRow
  let columns: MatchColumns
  let onOpen: () -> ()
  let onDelete: () -> ()

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      HStack(alignment: .center, spacing: MatchTableLayout.columnSpacing) {
        Text("\(index)")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(width: MatchTableLayout.indexWidth, alignment: .trailing)
        requestedColumn
          .frame(width: columns.requested, alignment: .leading)
        matchColumn
          .frame(width: columns.match, alignment: .leading)
      }
      .frame(height: MatchTableLayout.rowHeight)
      .contentShape(Rectangle())
      .onTapGesture(perform: onOpen)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(matchAccessibilityLabel)
      .accessibilityAddTraits(.isButton)

      Button(action: onDelete) {
        Image(systemName: "trash")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(width: MatchTableLayout.deleteButtonWidth, height: MatchTableLayout.rowHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Delete track")
    }
  }

  private var requestedColumn: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(row.queryTitle)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.primary)
      if !row.querySubtitle.isEmpty {
        Text(row.querySubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }

  private var matchColumn: some View {
    HStack(alignment: .center, spacing: MatchTableLayout.unit) {
      artwork
      Image(systemName: statusSymbol)
        .font(.body)
        .foregroundStyle(statusColor)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(matchTitle)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(.primary)
        if let detail = matchDetail {
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .layoutPriority(1)
      if row.status == .missing {
        Button("Find Match", action: onOpen)
          .buttonStyle(.bordered)
          .buttonBorderShape(.roundedRectangle(radius: 6))
          .controlSize(.small)
          .fixedSize(horizontal: true, vertical: false)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var artwork: some View {
    if let candidate = displayedCandidate {
      MatchArtworkView(objectID: candidate.objectID)
    } else {
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.secondary.opacity(0.15))
        .frame(width: MatchTableLayout.artwork, height: MatchTableLayout.artwork)
        .overlay {
          Image(systemName: "music.note")
            .font(.body)
            .foregroundStyle(.secondary)
        }
    }
  }

  private var displayedCandidate: PlaylistSongCandidate? {
    switch row.status {
    case .matched:
      return row.selected
    case .needsReview:
      return row.suggestion
    case .missing:
      return nil
    }
  }

  private var statusSymbol: String {
    switch row.status {
    case .matched: return "checkmark.circle.fill"
    case .needsReview: return "exclamationmark.triangle.fill"
    case .missing: return "xmark.circle.fill"
    }
  }

  private var statusColor: Color {
    switch row.status {
    case .matched: return .green
    case .needsReview: return .orange
    case .missing: return .secondary
    }
  }

  private var matchTitle: String {
    switch row.status {
    case .matched:
      return row.selected?.title ?? "Matched"
    case .needsReview:
      return row.suggestion?.title ?? "Needs review"
    case .missing:
      return "Missing"
    }
  }

  private var matchDetail: String? {
    switch row.status {
    case .matched:
      return row.selected?.subtitle
    case .needsReview:
      return row.suggestion?.subtitle
    case .missing:
      return row.error ?? "Not in your library"
    }
  }

  private var matchAccessibilityLabel: String {
    switch row.status {
    case .matched:
      return "Matched \(row.selected?.title ?? ""). Double tap to change."
    case .needsReview:
      return "Needs review \(row.suggestion?.title ?? ""). Double tap to choose a match."
    case .missing:
      return "Missing. Find Match."
    }
  }
}

// MARK: - PlaylistAddTrackRow

private struct PlaylistAddTrackRow: View {
  let isEnabled: Bool
  let onAdd: (String) async -> Bool

  @State
  private var draft = ""

  var body: some View {
    HStack(spacing: MatchTableLayout.columnSpacing) {
      Image(systemName: "plus")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: MatchTableLayout.indexWidth)
      TextField("Add a track: Artist - Title", text: $draft)
        .textFieldStyle(.roundedBorder)
        .font(.body)
        .disabled(!isEnabled)
        .onSubmit(submit)
      Button("Add", action: submit)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .controlSize(.small)
        .disabled(!canAdd)
    }
    .frame(height: MatchTableLayout.rowHeight)
  }

  private var canAdd: Bool {
    isEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit() {
    guard canAdd else { return }
    let line = draft
    Task {
      if await onAdd(line) {
        draft = ""
      }
    }
  }
}

// MARK: - PlaylistMatchPickerSheet

private struct PlaylistMatchPickerSheet: View {
  @ObservedObject
  var model: PlaylistGeneratorModel
  let themeColor: Color

  @State
  private var query = ""
  @State
  private var seed = ""
  @State
  private var pending: PlaylistSongCandidate?
  @State
  private var searchTask: Task<(), Never>?
  @FocusState
  private var searchFocused: Bool

  private let resultsHeightLimit: CGFloat = 300

  var body: some View {
    Group {
      if let row = model.reviewingRow {
        picker(for: row)
      } else {
        ProgressView()
          .frame(width: 520, height: 160)
      }
    }
    .modifier(FittedPresentationModifier())
    .presentationDragIndicator(.hidden)
  }

  private func picker(for row: PlaylistMatchRow) -> some View {
    let results = visibleResults(for: row)
    let searching = model.searchingRowID == row.id
    return VStack(alignment: .leading, spacing: 16) {
      Text("Choose Match")
        .font(.title3)
        .fontWeight(.semibold)

      VStack(alignment: .leading, spacing: 2) {
        Text("MATCHING SONG")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(row.queryTitle)
          .font(.headline)
          .lineLimit(1)
        if !row.querySubtitle.isEmpty {
          Text(row.querySubtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search title or artist", text: $query)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($searchFocused)
          .onSubmit { flushSearch(for: row.id) }
        if searching {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 36)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.35))
      )

      if let error = row.error, results.isEmpty, !searching {
        Text(error)
          .font(.subheadline)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Text(resultsTitle(for: row))
          .font(.headline)
        Spacer(minLength: 8)
        Text(resultsCountLabel(results.count))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      resultsList(results, row: row)

      Divider()

      HStack(spacing: 8) {
        Button("Mark as missing") {
          model.select(nil, for: row.id)
        }
        .buttonStyle(.borderless)
        Spacer(minLength: 8)
        Button("Cancel", action: model.closeReview)
          .keyboardShortcut(.cancelAction)
        Button("Use Selected Match") {
          confirm(row)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(themeColor)
        .disabled(pending == nil || searching)
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear { prepare(row) }
    .onChange(of: query) { newValue in
      model.updateManualQuery(newValue, for: row.id)
      guard newValue != seed else { return }
      scheduleSearch(for: row.id)
    }
    .modifier(PlaylistMatchKeyPressModifier(
      onUp: { moveSelection(-1, in: results) },
      onDown: { moveSelection(1, in: results) },
      onReturn: {
        guard !searchFocused else { return }
        confirm(row)
      }
    ))
    .onDisappear { searchTask?.cancel() }
  }

  @ViewBuilder
  private func resultsList(
    _ results: [PlaylistSongCandidate],
    row: PlaylistMatchRow
  )
    -> some View {
    if results.isEmpty {
      Text(emptyMessage(for: row))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(results) { candidate in
            resultRow(candidate, selected: pending?.id == candidate.id) {
              pending = candidate
            }
          }
        }
      }
      .frame(height: min(CGFloat(results.count) * MatchTableLayout.rowHeight, resultsHeightLimit))
    }
  }

  private func resultRow(
    _ candidate: PlaylistSongCandidate,
    selected: Bool,
    onSelect: @escaping () -> ()
  )
    -> some View {
    Button(action: onSelect) {
      HStack(alignment: .center, spacing: 10) {
        MatchArtworkView(objectID: candidate.objectID)
        VStack(alignment: .leading, spacing: 1) {
          Text(candidate.title)
            .font(.body)
            .lineLimit(1)
            .truncationMode(.tail)
          if !candidate.subtitle.isEmpty {
            Text(candidate.subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .foregroundStyle(.primary)
        Spacer(minLength: 8)
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(themeColor)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: MatchTableLayout.rowHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(selected ? themeColor.opacity(0.12) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(candidate.title), \(candidate.subtitle)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func visibleResults(for row: PlaylistMatchRow) -> [PlaylistSongCandidate] {
    query == seed ? row.candidates : row.manualResults
  }

  private func resultsTitle(for row: PlaylistMatchRow) -> String {
    query == seed ? "Suggested matches" : "Search results"
  }

  private func resultsCountLabel(_ count: Int) -> String {
    count == 1 ? "1 result" : "\(count) results"
  }

  private func emptyMessage(for row: PlaylistMatchRow) -> String {
    if model.searchingRowID == row.id {
      return "Searching your library…"
    }
    if query != seed {
      return "No results for “\(query)”."
    }
    return "No suggestions. Try another search."
  }

  private func prepare(_ row: PlaylistMatchRow) {
    guard seed.isEmpty, query.isEmpty else { return }
    let existing = row.manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = existing.isEmpty
      ? [row.querySubtitle, row.queryTitle].filter { !$0.isEmpty }.joined(separator: " ")
      : existing
    seed = initial
    query = initial
    model.updateManualQuery(initial, for: row.id)
    if row.confirmed {
      pending = row.selected
    }
    searchFocused = true
    if row.candidates.isEmpty, !initial.isEmpty {
      flushSearch(for: row.id)
    }
  }

  private func scheduleSearch(for rowID: UUID) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    searchTask = Task {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      await model.searchManually(rowID: rowID)
    }
  }

  private func flushSearch(for rowID: UUID) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    searchTask = Task { await model.searchManually(rowID: rowID) }
  }

  private func moveSelection(_ delta: Int, in results: [PlaylistSongCandidate]) {
    guard !results.isEmpty else { return }
    let current = results.firstIndex { $0.id == pending?.id } ?? (delta > 0 ? -1 : 0)
    let next = min(max(current + delta, 0), results.count - 1)
    pending = results[next]
  }

  private func confirm(_ row: PlaylistMatchRow) {
    guard let pending else { return }
    model.select(pending, for: row.id)
  }
}

// MARK: - PlaylistNameSheet

private struct PlaylistNameSheet: View {
  @Binding
  var name: String
  let matchedCount: Int
  let excludedCount: Int
  let themeColor: Color
  let isCreating: Bool
  let errorMessage: String?
  let onCancel: () -> ()
  let onCreate: () -> ()

  @FocusState
  private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Create Playlist")
        .font(.title3)
        .fontWeight(.semibold)
      Text("Save your matched songs as a new playlist.")
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        Text("Playlist name")
          .font(.headline)
        TextField("Playlist name", text: $name)
          .textFieldStyle(.roundedBorder)
          .font(.body)
          .focused($nameFocused)
          .onSubmit(submitIfValid)
          .disabled(isCreating)
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(includedSummary)
          .font(.body)
        if excludedCount > 0 {
          Text(excludedSummary)
            .font(.body)
            .foregroundStyle(.secondary)
        }
      }

      if let errorMessage, !errorMessage.isEmpty {
        Text(errorMessage)
          .font(.subheadline)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Spacer()
        if isCreating {
          ProgressView()
            .controlSize(.small)
        }
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isCreating)
        Button("Create Playlist", action: onCreate)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(themeColor)
          .disabled(!canCreate)
      }
    }
    .padding(20)
    .frame(width: 380)
    .fixedSize(horizontal: false, vertical: true)
    .modifier(FittedPresentationModifier())
    .presentationDragIndicator(.hidden)
    .onAppear { nameFocused = true }
  }

  private var canCreate: Bool {
    !trimmedName.isEmpty && !isCreating
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var includedSummary: String {
    matchedCount == 1 ? "1 song will be included." : "\(matchedCount) songs will be included."
  }

  private var excludedSummary: String {
    excludedCount == 1
      ? "1 song will not be added."
      : "\(excludedCount) songs will not be added."
  }

  private func submitIfValid() {
    guard canCreate else { return }
    onCreate()
  }
}

// MARK: - MatchArtworkView

private struct MatchArtworkView: UIViewRepresentable {
  let objectID: NSManagedObjectID

  func makeUIView(context: Context) -> FixedArtworkView {
    FixedArtworkView()
  }

  func updateUIView(_ host: FixedArtworkView, context: Context) {
    guard context.coordinator.shownID != objectID else { return }
    context.coordinator.shownID = objectID
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
          let managed = try? appDelegate.storage.main.context
          .existingObject(with: objectID) as? SongMO
    else { return }
    host.imageView.displayAndUpdate(entity: Song(managedObject: managed))
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: FixedArtworkView,
    context: Context
  )
    -> CGSize? {
    CGSize(width: MatchTableLayout.artwork, height: MatchTableLayout.artwork)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var shownID: NSManagedObjectID?
  }
}

// MARK: - FixedArtworkView

/// Keeps song art at a fixed thumbnail. `LibraryEntityImage` otherwise reports the full image size.
private final class FixedArtworkView: UIView {
  let imageView = LibraryEntityImage(frame: .zero)

  override init(frame: CGRect) {
    super.init(frame: CGRect(
      x: 0,
      y: 0,
      width: MatchTableLayout.artwork,
      height: MatchTableLayout.artwork
    ))
    clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: MatchTableLayout.artwork, height: MatchTableLayout.artwork)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    intrinsicContentSize
  }
}

// MARK: - iOS 16 compatibility helpers

private struct ScrollContentMarginsZeroModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 0, for: .scrollContent)
    } else {
      content
    }
  }
}

private struct PlaylistMatchKeyPressModifier: ViewModifier {
  let onUp: () -> Void
  let onDown: () -> Void
  let onReturn: () -> Void

  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content
        .onKeyPress(.upArrow) {
          onUp()
          return .handled
        }
        .onKeyPress(.downArrow) {
          onDown()
          return .handled
        }
        .onKeyPress(.return) {
          onReturn()
          return .handled
        }
    } else {
      content
    }
  }
}


private struct FittedPresentationModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.presentationSizing(.fitted)
    } else {
      content
    }
  }
}
