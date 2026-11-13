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
    if #available(iOS 17.0, *) {
      removeLegacyUnavailableOverlay()
      guard let content else {
        contentUnavailableConfiguration = nil
        return
      }
      if content.text == AmperfyUnavailableContent.search().text,
         content.secondaryText == AmperfyUnavailableContent.search().secondaryText {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        return
      }
      var config = UIContentUnavailableConfiguration.empty()
      config.image = content.image
      config.text = content.text
      config.secondaryText = content.secondaryText
      contentUnavailableConfiguration = config
    } else {
      applyLegacyUnavailableOverlay(content)
    }
  }

  private func removeLegacyUnavailableOverlay() {
    view.viewWithTag(Self.unavailableOverlayTag)?.removeFromSuperview()
  }

  private func applyLegacyUnavailableOverlay(_ content: AmperfyUnavailableContent?) {
    removeLegacyUnavailableOverlay()
    guard let content else { return }

    let overlay = UIView()
    overlay.tag = Self.unavailableOverlayTag
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.isUserInteractionEnabled = false

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
      label.font = .preferredFont(forTextStyle: .headline)
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
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
    ])
  }
}
