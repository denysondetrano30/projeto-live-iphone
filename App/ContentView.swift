import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var link = PCLink()
    @StateObject private var usb = USBLink()
    @State private var showGrid = true
    @State private var isScanning = false
    @State private var scanHint: String?
    @State private var notice: String?

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
                        onPinch: { scale, state in camera.pinch(scale: scale, state: state) },
                        onOrientation: { orientation in camera.setVideoOrientation(orientation) }
                    )
                    if showGrid {
                        GridOverlay(landscape: landscape)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()

            statusMessage

            if isScanning {
                scanningOverlay
            } else {
                VStack {
                    topBar
                    if let notice {
                        Text(notice)
                            .font(.subheadline.bold())
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green)
                            .cornerRadius(8)
                    }
                    Spacer()
                    bottomBar
                }
                .padding(12)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let wifi = link
            let cable = usb
            camera.attach { buffer in
                wifi.send(buffer)
                cable.send(buffer)
            }
            camera.start()
            link.start()
            usb.start()
        }
    }

    // MARK: - Partes da tela

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(linkColor)
                .frame(width: 10, height: 10)
            Text("\(link.cameraName) · \(linkText)")
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Text("v\(PCLink.appVersion)")
                .font(.caption2)
                .opacity(0.6)
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

            Button {
                startScanning()
            } label: {
                Label("Parear", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(RoundButtonStyle(active: link.pairing == nil))
        }
    }

    // MARK: - Pareamento por QR code

    private var scanningOverlay: some View {
        VStack(spacing: 14) {
            Text("Aponte para o QR code na imagem da fonte \"Celular\" do OBS")
                .font(.headline)
                .multilineTextAlignment(.center)
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.yellow, lineWidth: 3)
                .frame(width: 220, height: 220)
            if let scanHint {
                Text(scanHint)
                    .font(.subheadline.bold())
                    .foregroundColor(.yellow)
            }
            HStack(spacing: 12) {
                Button("Cancelar") {
                    stopScanning()
                }
                .buttonStyle(RoundButtonStyle(active: false))
                if let pairing = link.pairing {
                    Button("Desfazer pareamento com \"\(pairing.sourceName)\"") {
                        link.setPairing(nil)
                        stopScanning()
                        showNotice("Pareamento desfeito")
                    }
                    .buttonStyle(RoundButtonStyle(active: false))
                }
            }
            .font(.subheadline.bold())
            .frame(minHeight: 44)
        }
        .foregroundColor(.white)
        .padding(20)
        .background(Color.black.opacity(0.55))
        .cornerRadius(16)
    }

    private func startScanning() {
        scanHint = nil
        isScanning = true
        camera.startScanning { text in
            guard let pairing = Pairing.parse(text) else {
                scanHint = "Esse QR code não é de uma fonte do Projeto Live"
                return
            }
            link.setPairing(pairing)
            stopScanning()
            showNotice("Pareado com \"\(pairing.sourceName)\"")
        }
    }

    private func stopScanning() {
        camera.stopScanning()
        isScanning = false
    }

    private func showNotice(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if notice == text {
                notice = nil
            }
        }
    }

    private var linkText: String {
        if usb.isConnected {
            return "Cabo USB · enviando para o PC"
        }
        switch link.state {
        case .starting:
            return "Preparando o envio para o PC…"
        case .noWifi:
            return "Sem Wi-Fi: conecte o iPhone na mesma rede do PC"
        case .waiting(let address):
            return "Sem pareamento · toque em Parear (ou no OBS use srt://\(address))"
        case .connecting(let source):
            return "Procurando o OBS (fonte \"\(source)\")…"
        case .sending(let status):
            return status
        case .failed(let message):
            return message
        }
    }

    private var linkColor: Color {
        if usb.isConnected {
            return .green
        }
        switch link.state {
        case .sending:
            return .green
        case .waiting, .connecting:
            return .yellow
        case .starting:
            return .gray
        case .noWifi, .failed:
            return .red
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
