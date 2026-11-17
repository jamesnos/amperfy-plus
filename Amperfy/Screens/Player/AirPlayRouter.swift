//
//  AirPlayRouter.swift
//  Amperfy
//
//  Presents the system audio route (AirPlay) picker reliably on iPadOS 16+,
//  including from inside page/form sheets where hidden zero-size pickers no-op.
//

import AVFAudio
import AVKit
import UIKit

enum AirPlayRouter {
  /// Present the system route sheet from `host`, anchored near `sourceView`.
  @MainActor
  static func present(from host: UIViewController, sourceView: UIView) {
    // Keep the playback session active so AirPlay routes are offered.
    try? AVAudioSession.sharedInstance().setActive(true)

    // Reuse one picker per host so it stays in the window hierarchy.
    let picker = hostedPicker(on: host)
    let anchor = sourceView.convert(sourceView.bounds, to: host.view)
    let side: CGFloat = 44
    picker.frame = CGRect(
      x: anchor.midX - side / 2,
      y: anchor.midY - side / 2,
      width: side,
      height: side
    )
    // Must not be `isHidden` — hidden pickers often fail to present on iPadOS 16.
    picker.isHidden = false
    picker.alpha = 0.02
    picker.isUserInteractionEnabled = true
    host.view.bringSubviewToFront(picker)
    host.view.layoutIfNeeded()

    // Defer so the picker finishes attaching to the window, then retry once.
    DispatchQueue.main.async {
      activate(picker)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        activate(picker)
      }
    }
  }

  @MainActor
  private static func hostedPicker(on host: UIViewController) -> AVRoutePickerView {
    let tag = 911_184_801 // unique host-view tag for the retained route picker
    if let existing = host.view.viewWithTag(tag) as? AVRoutePickerView {
      return existing
    }
    let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    picker.tag = tag
    picker.prioritizesVideoDevices = false
    picker.tintColor = .label
    host.view.addSubview(picker)
    return picker
  }

  @MainActor
  private static func activate(_ picker: AVRoutePickerView) {
    if let control = firstControl(in: picker) {
      control.sendActions(for: .touchUpInside)
      return
    }
    // Last resort: synthesize a tap in the picker's center.
    let center = CGPoint(x: picker.bounds.midX, y: picker.bounds.midY)
    if let target = picker.hitTest(center, with: nil) as? UIControl {
      target.sendActions(for: .touchUpInside)
    }
  }

  private static func firstControl(in view: UIView) -> UIControl? {
    if let control = view as? UIControl {
      return control
    }
    for subview in view.subviews {
      if let found = firstControl(in: subview) {
        return found
      }
    }
    return nil
  }
}
