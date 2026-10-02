import Foundation

nonisolated enum EngineerShortcutFiles {
    static func prepare(_ commands: [EngineerShortcutDefinition], bundle: Bundle = .main) throws -> [URL] {
        let files = FileManager.default
        let root = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("EngineerShortcuts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try commands.map { command in
                guard let source = bundle.url(forResource: "engineer-" + command.id, withExtension: "shortcut"),
                      try Data(contentsOf: source).prefix(4) == Data("AEA1".utf8) else {
                    throw AppServiceError.message("Готовый файл команды «\(command.title)» отсутствует в этой сборке.")
                }
                let destination = directory.appendingPathComponent(command.title + ".shortcut")
                try files.copyItem(at: source, to: destination)
                return destination
            }
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}
