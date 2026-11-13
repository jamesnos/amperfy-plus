//
//  ContentUnavailableCompat.swift
//  Amperfy
//
//  iOS 16-compatible empty / search unavailable content.
//

import UIKit

struct AmperfyUnavailableContent {
  var image: UIImage?
  var text: String?
  var secondaryText: String?

  static func search() -> AmperfyUnavailableContent {
    AmperfyUnavailableContent(
      image: UIImage(systemName: "magnifyingglass"),
      text: "No Results",
      secondaryText: "Try a different search."
    )
  }

  static func empty(
    image: UIImage?,
    text: String?,
    secondaryText: String?
  )
    -> AmperfyUnavailableContent {
    AmperfyUnavailableContent(image: image, text: text, secondaryText: secondaryText)
  }
}

extension UIViewController {
  private static var unavailableOverlayTag = 9_711_604

  func setAmperfyUnavailableContent(_ content: AmperfyUnavailableContent?) {
    // Always use our centered overlay. UIContentUnavailableConfiguration on iPad
    // (and overlay-as-table-subview) sits under the search bar instead of mid-screen.
    if #available(iOS 17.0, *) {
      contentUnavailableConfiguration = nil
    }
    applyLegacyUnavailableOverlay(content)
  }

  private func removeLegacyUnavailableOverlay() {
    if let tableVC = self as? UITableViewController,
       tableVC.tableView.backgroundView?.tag == Self.unavailableOverlayTag {
      tableVC.tableView.backgroundView = nil
    }
    if let collectionVC = self as? UICollectionViewController,
       collectionVC.collectionView.backgroundView?.tag == Self.unavailableOverlayTag {
      collectionVC.collectionView.backgroundView = nil
    }
    view.viewWithTag(Self.unavailableOverlayTag)?.removeFromSuperview()
  }

  private func makeUnavailableOverlay(_ content: AmperfyUnavailableContent) -> UIView {
    let overlay = UIView()
    overlay.tag = Self.unavailableOverlayTag
    overlay.isUserInteractionEnabled = false
    overlay.backgroundColor = .clear

    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    if let image = content.image {
      let imageView = UIImageView(image: image.withRenderingMode(.alwaysTemplate))
      imageView.tintColor = .secondaryLabel
      imageView.contentMode = .scaleAspectFit
      imageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        imageView.widthAnchor.constraint(equalToConstant: 48),
        imageView.heightAnchor.constraint(equalToConstant: 48),
      ])
      stack.addArrangedSubview(imageView)
    }
    if let text = content.text {
      let label = UILabel()
      label.text = text
      label.font = .preferredFont(forTextStyle: .title2)
      label.textColor = .label
      label.textAlignment = .center
      label.numberOfLines = 0
      stack.addArrangedSubview(label)
    }
    if let secondaryText = content.secondaryText {
      let label = UILabel()
      label.text = secondaryText
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.textColor = .secondaryLabel
      label.textAlignment = .center
      label.numberOfLines = 0
      stack.addArrangedSubview(label)
    }

    overlay.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
    ])
    return overlay
  }

  private func applyLegacyUnavailableOverlay(_ content: AmperfyUnavailableContent?) {
    removeLegacyUnavailableOverlay()
    guard let content else { return }

    let overlay = makeUnavailableOverlay(content)

    if let tableVC = self as? UITableViewController {
      // backgroundView is sized to the visible table bounds (below search), so
      // centerY is truly mid-screen — not the top of the scroll content.
      tableVC.tableView.backgroundView = overlay
      return
    }
    if let collectionVC = self as? UICollectionViewController {
      collectionVC.collectionView.backgroundView = overlay
      return
    }

    overlay.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
  }
}
