import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showGrid = true

    private let zoomSteps: [CGFloat] = [1, 2, 3]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                ZStack {
                    CameraPreview(
                        session: camera.session,
                        onTap: { point in camera.focus(at: point) },
                        onPinch: { scale, state in camera.pinch(scale: scale, state: state) }
                    )
                    if showGrid {
                        GridOverlay(landscape: landscape)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()

            statusMessage

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(12)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
    }

    // MARK: - Partes da tela

    private var topBar: some View {
        HStack {
            Text("Projeto Live · câmera")
                .font(.caption.bold())
            Text("envio para o PC: em breve")
                .font(.caption)
                .opacity(0.8)
            Spacer()
            Text(String(format: "%.1fx", Double(camera.zoomFactor)))
                .font(.caption.monospacedDigit().bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            ForEach(zoomSteps.filter { $0 <= camera.maxZoom }, id: \.self) { step in
                Button {
                    camera.setZoom(step, smooth: true)
                } label: {
                    Text("\(Int(step))x")
                        .font(.subheadline.bold())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(RoundButtonStyle(active: abs(camera.zoomFactor - step) < 0.05))
            }

            Spacer()

            Button {
                showGrid.toggle()
            } label: {
                Label("Grade", systemImage: "squareshape.split.3x3")
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(RoundButtonStyle(active: showGrid))

            Button {
                camera.toggleLock()
            } label: {
                Label(camera.isLocked ? "Travado" : "Travar", systemImage: camera.isLocked ? "lock.fill" : "lock.open")
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(RoundButtonStyle(active: camera.isLocked))
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch camera.status {
        case .starting:
            ProgressView("Ligando a câmera…")
                .tint(.white)
                .foregroundColor(.white)
        case .running:
            EmptyView()
        case .denied:
            messageBox("Sem acesso à câmera. Abra Ajustes > Projeto Live e ative a Câmera.")
        case .failed(let reason):
            messageBox(reason)
        }
    }

    private func messageBox(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
            .padding(16)
            .background(Color.black.opacity(0.7))
            .cornerRadius(10)
            .padding(24)
    }
}

struct RoundButtonStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(active ? .black : .white)
            .padding(.horizontal, 8)
            .background(active ? Color.yellow : Color.black.opacity(0.55))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
