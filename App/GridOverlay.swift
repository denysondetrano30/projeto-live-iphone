import SwiftUI

/// Desenha a grade de terços e, com o celular deitado, o recorte vertical 9:16 do meio da imagem.
struct GridOverlay: View {
    let landscape: Bool

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoRect(in: geometry.size, landscape: landscape)
            ZStack {
                if landscape {
                    let verticalWidth = video.height * 9.0 / 16.0
                    let sideWidth = (video.width - verticalWidth) / 2.0

                    // Escurece as laterais que ficam fora do vídeo vertical.
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: sideWidth, height: video.height)
                        .position(x: video.minX + sideWidth / 2.0, y: video.midY)
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: sideWidth, height: video.height)
                        .position(x: video.maxX - sideWidth / 2.0, y: video.midY)

                    Rectangle()
                        .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                        .frame(width: verticalWidth, height: video.height)
                        .position(x: video.midX, y: video.midY)

                    Text("Vertical 9:16")
                        .font(.caption.bold())
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        // Abaixo da barra de status do topo, para não ficar escondido.
                        .position(x: video.midX, y: video.minY + 76)
                }

                ThirdsGrid()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    .frame(width: video.width, height: video.height)
                    .position(x: video.midX, y: video.midY)
            }
        }
    }

    /// Onde a imagem da câmera aparece dentro da tela (16:9 deitado, 9:16 em pé).
    static func videoRect(in size: CGSize, landscape: Bool) -> CGRect {
        let aspect: CGFloat = landscape ? 16.0 / 9.0 : 9.0 / 16.0
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(
            x: (size.width - width) / 2.0,
            y: (size.height - height) / 2.0,
            width: width,
            height: height
        )
    }
}

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for step in 1...2 {
            let fraction = CGFloat(step) / 3.0
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
