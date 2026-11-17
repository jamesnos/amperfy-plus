//
//  DirectorySongListView.swift
//  Amperfy
//
//  Tools → Song List from Folder: scan a directory and show Artist - Title in-app.
//

import AmperfyKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DirectorySongListHostVC

final class DirectorySongListHostVC: UIViewController, UIDocumentPickerDelegate {
  private let model = DirectorySongListModel()
  private var hostingController: UIHostingController<DirectorySongListView>!

  init() {
    super.init(nibName: nil, bundle: nil)
    title = "Song List from Folder"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let root = DirectorySongListView(
      model: model,
      onBrowse: { [weak self] in self?.presentFolderPicker() }
    )
    let host = UIHostingController(rootView: root)
    hostingController = host
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed {
      model.cleanup()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let hostVC = AppDelegate.mainWindowHostVC else { return }
    let bottom = hostVC.getSafeAreaExtension()
    if additionalSafeAreaInsets.bottom != bottom {
      extendSafeAreaToAccountForMiniPlayer()
    }
  }

  private func presentFolderPicker() {
    // UIDocumentPicker is reliable here; SwiftUI `.fileImporter` inside a
    // UIHostingController in the split/sidebar stack often freezes on iPad/Mac.
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.modalPresentationStyle = .formSheet
    present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    model.setFolderURL(url)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
}

// MARK: - DirectorySongListView

struct DirectorySongListView: View {
  @ObservedObject
  var model: DirectorySongListModel
  var onBrowse: () -> ()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      controls
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

      Divider()

      if model.entries.isEmpty, !model.isScanning {
        emptyState
      } else {
        listBody
      }
    }
    .navigationTitle("Song List from Folder")
    #if !targetEnvironment(macCatalyst)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Folder")
        .font(.headline)
      HStack(spacing: 8) {
        TextField("Path or smb://…", text: $model.folderPath)
          .textFieldStyle(.roundedBorder)
          .font(.body)
          .disabled(model.isScanning)
          .onSubmit {
            if model.canScan { model.startScan() }
          }
        Button("Browse…", action: onBrowse)
          .disabled(model.isScanning)
      }

      HStack(spacing: 12) {
        Toggle("Sort A–Z", isOn: $model.sortAlphabetically)
          .toggleStyle(SongListCheckboxToggleStyle())
        Toggle("Unique only", isOn: $model.uniqueOnly)
          .toggleStyle(SongListCheckboxToggleStyle())
        Spacer()
        if model.isScanning {
          ProgressView()
            .controlSize(.small)
          Button("Cancel", action: model.cancelScan)
        } else {
          Button("Scan Folder") { model.startScan() }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canScan)
          Button("Copy List", action: model.copyListToPasteboard)
            .disabled(model.displayLines.isEmpty)
        }
      }
      .font(.subheadline)

      if !model.progressText.isEmpty {
        Text(model.progressText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if !model.statusMessage.isEmpty {
        Text(model.statusMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "folder.badge.questionmark")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Choose a music folder to list Artist - Title lines.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var listBody: some View {
    List {
      Section {
        ForEach(Array(model.displayLines.enumerated()), id: \.offset) { index, line in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .trailing)
            Text(line)
              .font(.body)
              .textSelection(.enabled)
          }
          .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
      } header: {
        Text("\(model.displayLines.count) songs")
      }
    }
    .listStyle(.plain)
  }
}

// MARK: - Checkbox toggle (Mac / iPad friendly)

private struct SongListCheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
        configuration.label
      }
    }
    .buttonStyle(.plain)
  }
}
