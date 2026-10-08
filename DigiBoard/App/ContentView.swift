import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalCanvasView(renderer: renderer, preferredFPS: 30)
                    .ignoresSafeArea()

                VStack {
                    HStack(spacing: 12) {
                        Label(model.status, systemImage: "rectangle.on.rectangle")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        if model.inferenceMillis > 0 {
                            Text(String(format: "推理 %.1f ms", model.inferenceMillis))
                                .font(.footnote.monospacedDigit())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    Spacer()
                }
                .padding(.top, 8)
            } else {
                ProgressView(model.status)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
