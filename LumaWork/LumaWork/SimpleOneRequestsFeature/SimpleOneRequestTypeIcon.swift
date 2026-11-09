import SwiftUI

/// Request type outlines reproduced from the coordination reference screenshots.
struct SimpleOneRequestTypeIcon: View {
    let requestType: String

    private var kind: RequestTypeSymbol.Kind? {
        let token = requestType.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        switch token.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "install", "установка": return .install
        case "dismounting", "демонтаж": return .dismounting
        case "returnequip", "возврат": return .returnEquipment
        case "servicestd", "сервис", "сервисная": return .service
        default: return nil
        }
    }

    private var systemSymbol: String {
        let token = requestType.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        switch token {
        case "replacement", "замена": return "arrow.triangle.2.circlepath"
        case "expertise", "экспертиза": return "magnifyingglass"
        default: return "doc.text"
        }
    }

    var body: some View {
        Group {
            if let kind {
                RequestTypeSymbol(kind: kind)
                    .fill()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Image(systemName: systemSymbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RequestTypeSymbol: Shape {
    enum Kind { case install, dismounting, service, returnEquipment }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let lines: [[CGFloat]]
        switch kind {
        case .install:
            lines = [
                [5, 3, 19, 3, 22, 14, 2, 14, 5, 3],
                [8, 6, 16, 6, 17, 11, 7, 11, 8, 6],
                [12, 18, 12, 23],
                [9, 20, 12, 23, 15, 20]
            ]
        case .dismounting:
            lines = [
                [3, 5, 21, 5, 21, 11, 3, 11, 3, 5],
                [9, 5, 9, 2, 15, 2, 15, 5],
                [10, 11, 10, 23, 14, 23, 14, 11],
                [10, 16, 14, 16]
            ]
        case .service:
            lines = [
                [3, 2, 21, 2, 21, 14, 3, 14, 3, 2],
                [7, 2, 7, 7],
                [11, 2, 11, 5],
                [15, 2, 15, 7],
                [18, 2, 18, 5],
                [10, 14, 10, 23, 14, 23, 14, 14],
                [10, 18, 14, 18]
            ]
        case .returnEquipment:
            lines = [
                [6, 10, 2, 14, 6, 18],
                [2, 14, 11, 14],
                [13, 17, 10, 20, 13, 23],
                [10, 20, 17, 20],
                [15, 2, 17, 3, 19, 2, 20, 4, 22, 5, 21, 7, 22, 9, 20, 10, 19, 12, 17, 11, 15, 12, 14, 10, 12, 9, 13, 7, 12, 5, 14, 4, 15, 2]
            ]
        }
        var path = Path()
        for line in lines {
            path.move(to: CGPoint(x: line[0], y: line[1]))
            for index in stride(from: 2, to: line.count, by: 2) {
                path.addLine(to: CGPoint(x: line[index], y: line[index + 1]))
            }
        }
        if kind == .returnEquipment {
            path.addEllipse(in: CGRect(x: 15, y: 5, width: 4, height: 4))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
