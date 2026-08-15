import AVFoundation
import AVKit
import SwiftUI

/// A `UIView` whose backing layer *is* an `AVPlayerLayer`.
///
/// Overriding `layerClass` rather than adding a sublayer is the standard trick:
/// the layer then resizes with the view automatically, so there is no
/// `layoutSubviews` bookkeeping and no frame drift during rotation.
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The video surface, with no controls of its own.
///
/// Used on **both** platforms now that tvOS draws its own controls too.
/// `AVPlayerViewController` is the right choice when you want the system
/// controls — it is emphatically the wrong one when you are drawing your own,
/// because with `showsPlaybackControls = false` it becomes an opaque box that
/// still owns gestures and still insets your layout.
///
/// A bare `AVPlayerLayer` also hands us the object `AVPictureInPictureController`
/// needs, which `AVPlayerViewController` never exposes.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    /// Called once, with the layer, so the engine can attach PiP to it.
    var onLayerReady: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        onLayerReady(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

#if os(iOS)

    /// The AirPlay button.
    ///
    /// There is no SwiftUI equivalent and no API to trigger the route picker
    /// yourself — `AVRoutePickerView` *is* the control, so it gets wrapped and
    /// restyled rather than reimplemented. Tinting is the only customisation it
    /// allows, which is why this one button does not match the others' sizing
    /// exactly.
    ///
    /// iOS only: a TV has no route to pick, since it *is* the output.
    struct RoutePickerButton: UIViewRepresentable {
        var tint: UIColor = .white

        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.tintColor = tint
            view.activeTintColor = .systemBlue
            view.prioritizesVideoDevices = true
            return view
        }

        func updateUIView(_ view: AVRoutePickerView, context: Context) {
            view.tintColor = tint
        }

        /// Without this, `AVRoutePickerView` reports a much larger intrinsic
        /// size, overflows the `.frame(width:height:)` around it, and paints
        /// over its neighbour.
        ///
        /// `.frame` sets the *layout* size; it does not stop a UIKit view from
        /// drawing outside it. `sizeThatFits` is how a representable reports a
        /// size to SwiftUI, and it is worth implementing for any wrapped control
        /// that sits in a row with others.
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: AVRoutePickerView,
            context: Context
        ) -> CGSize? {
            CGSize(width: 44, height: 44)
        }
    }

#endif
