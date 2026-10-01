import Foundation

public enum DownloadRisk: String, Codable, Equatable, Sendable {
    case executable, script, installer, diskImage, archive, disguisedExecutable

    public var isHighRisk: Bool {
        switch self {
        case .executable, .script, .installer, .disguisedExecutable: true
        case .diskImage, .archive: false
        }
    }
}

public enum DownloadRiskClassifier {
    private static let executables: Set<String> = ["app", "command", "exe", "bin", "dylib"]
    private static let scripts: Set<String> = ["sh", "zsh", "bash", "fish", "py", "rb", "pl", "js"]

    public static func risks(filename: String, prefix: Data = Data()) -> [DownloadRisk] {
        let parts = filename.lowercased().split(separator: ".").map(String.init)
        let ext = parts.last ?? ""
        var risks: [DownloadRisk] = []
        if executables.contains(ext) { risks.append(.executable) }
        if scripts.contains(ext) { risks.append(.script) }
        if ["pkg", "mpkg"].contains(ext) { risks.append(.installer) }
        if ext == "dmg" { risks.append(.diskImage) }
        if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz"].contains(ext) { risks.append(.archive) }

        let bytes = Array(prefix.prefix(4))
        let machO: Set<[UInt8]> = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe],
        ]
        if machO.contains(bytes), !executables.contains(ext) {
            risks.append(.disguisedExecutable)
        }
        return risks
    }
}
