import AppKit
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    static var isSupported: Bool {
        NSClassFromString("NSVisualEffectView") != nil
    }

    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#if DEBUG
    #Preview("Visual Effect Background") {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            VStack(spacing: 6) {
                Text("VoicePanel")
                    .font(.headline)
                Text("Native macOS material")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(width: 320, height: 150)
    }
#endif
