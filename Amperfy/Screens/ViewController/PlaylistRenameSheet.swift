//
//  PlaylistRenameSheet.swift
//  Amperfy
//
//  Rename playlist prompt styled like Playlist Generator's create-name sheet.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - PlaylistRenameSheet

struct PlaylistRenameSheet: View {
  @State
  private var name: String
  let themeColor: Color
  let onCancel: () -> ()
  let onRename: (String) -> ()

  @FocusState
  private var nameFocused: Bool

  init(
    initialName: String,
    themeColor: Color,
    onCancel: @escaping () -> (),
    onRename: @escaping (String) -> ()
  ) {
    _name = State(initialValue: initialName)
    self.themeColor = themeColor
    self.onCancel = onCancel
    self.onRename = onRename
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Playlist")
        .font(.title3)
        .fontWeight(.semibold)
      Text("Choose a new name for this playlist.")
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
      }
      .padding(.top, 4)

      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Rename", action: submitIfValid)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(themeColor)
          .disabled(!canRename)
      }
    }
    .padding(20)
    .frame(width: 380)
    .fixedSize(horizontal: false, vertical: true)
    .modifier(PlaylistRenameFittedPresentationModifier())
    .presentationDragIndicator(.hidden)
    .onAppear { nameFocused = true }
  }

  private var canRename: Bool {
    !trimmedName.isEmpty
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submitIfValid() {
    guard canRename else { return }
    onRename(trimmedName)
  }
}

// MARK: - PlaylistRenameFittedPresentationModifier

private struct PlaylistRenameFittedPresentationModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.presentationSizing(.fitted)
    } else {
      content
    }
  }
}

// MARK: - Presentation helper

enum PlaylistRenamePresenter {
  @MainActor
  static func present(
    from rootView: UIViewController,
    playlist: Playlist,
    themeColor: Color,
    onRename: @escaping (String) -> ()
  ) {
    let sheet = PlaylistRenameSheet(
      initialName: playlist.name,
      themeColor: themeColor,
      onCancel: { rootView.dismiss(animated: true) },
      onRename: { newName in
        rootView.dismiss(animated: true) {
          onRename(newName)
        }
      }
    )
    let host = UIHostingController(rootView: sheet)
    host.modalPresentationStyle = .formSheet
    host.preferredContentSize = CGSize(width: 420, height: 240)
    if let presentation = host.sheetPresentationController {
      presentation.prefersGrabberVisible = false
      if #available(iOS 16.0, *) {
        presentation.detents = [.medium()]
      }
    }
    rootView.present(host, animated: true)
  }
}
