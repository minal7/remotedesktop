import Foundation

/// A small, reviewed catalog of Agent Skills shipped inside the signed app bundle.
/// It only supplies model instructions; it never loads executable skill content.
struct ComputerUseSkillCatalog: Sendable {
    enum Audience: String, Sendable {
        case nativeMCP = "native-mcp"
        case browserFileIdentification = "browser-file-identification"
        case defaultBrowserControl = "default-browser-control"
        case defaultBrowserVisual = "default-browser-visual"
    }

    struct Skill: Equatable, Sendable {
        let name: String
        let description: String
        let audience: Audience
        let requiredTools: Set<String>
        let body: String
    }

    enum CatalogError: Error { case invalidManifest }
    let skills: [Skill]

    static func load(bundle: Bundle = .main) -> ComputerUseSkillCatalog {
        guard let root = bundle.resourceURL?.appendingPathComponent("ComputerUseSkills", isDirectory: true) else {
            NSLog("ComputerUseSkills bundle resource is unavailable; no skills were added to planning.")
            return ComputerUseSkillCatalog(skills: [])
        }
        do {
            return try load(from: root)
        } catch {
            NSLog("ComputerUseSkills resource failed validation; no skills were added to planning.")
            return ComputerUseSkillCatalog(skills: [])
        }
    }

    static func load(from root: URL) throws -> ComputerUseSkillCatalog {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CatalogError.invalidManifest
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var skills: [Skill] = []
        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw CatalogError.invalidManifest }
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard contents == ["SKILL.md"] else { throw CatalogError.invalidManifest }
            let manifest = directory.appendingPathComponent("SKILL.md")
            let manifestValues = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
                  let size = manifestValues.fileSize, size <= 16 * 1024 else { throw CatalogError.invalidManifest }
            let text = try String(contentsOf: manifest, encoding: .utf8)
            let skill = try parse(text)
            guard skill.name == directory.lastPathComponent else { throw CatalogError.invalidManifest }
            skills.append(skill)
        }
        return ComputerUseSkillCatalog(skills: skills)
    }

    func instructions(for audience: Audience, offeredTools: Set<String>) -> String? {
        let matching = skills.filter { $0.audience == audience && $0.requiredTools.isSubset(of: offeredTools) }
        guard !matching.isEmpty else { return nil }
        return matching.map { "Skill: \($0.name) — \($0.description)\n\($0.body)" }.joined(separator: "\n\n")
    }

    func augmenting(_ base: String, for audience: Audience, offeredTools: Set<String>) -> String {
        guard let skillInstructions = instructions(for: audience, offeredTools: offeredTools) else { return base }
        return base + "\n\n" + skillInstructions
    }

    private static func parse(_ text: String) throws -> Skill {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw CatalogError.invalidManifest }
        var name: String?
        var description: String?
        var audience: Audience?
        var requiredTools: Set<String>?
        var inMetadata = false
        var sawMetadata = false
        for line in lines[1..<end] {
            if line == "metadata:" {
                guard !inMetadata, !sawMetadata else { throw CatalogError.invalidManifest }
                inMetadata = true
                sawMetadata = true
                continue
            }
            if line.hasPrefix("  ") {
                guard inMetadata else { throw CatalogError.invalidManifest }
                let pair = line.dropFirst(2).split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { throw CatalogError.invalidManifest }
                let key = pair[0].trimmingCharacters(in: .whitespaces)
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw CatalogError.invalidManifest }
                switch key {
                case "audience":
                    guard audience == nil, let parsed = Audience(rawValue: value) else { throw CatalogError.invalidManifest }; audience = parsed
                case "required-tools":
                    guard requiredTools == nil else { throw CatalogError.invalidManifest }
                    let parsed = Set(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
                    guard !parsed.isEmpty, parsed.allSatisfy(Self.validToolName) else { throw CatalogError.invalidManifest }; requiredTools = parsed
                default: throw CatalogError.invalidManifest
                }
            } else {
                inMetadata = false
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { throw CatalogError.invalidManifest }
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                switch pair[0] {
                case "name": guard name == nil else { throw CatalogError.invalidManifest }; name = value
                case "description": guard description == nil else { throw CatalogError.invalidManifest }; description = value
                default: throw CatalogError.invalidManifest
                }
            }
        }
        let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              let description, !description.isEmpty, description.count <= 200,
              let audience, let requiredTools, !body.isEmpty else { throw CatalogError.invalidManifest }
        return Skill(name: name, description: description, audience: audience, requiredTools: requiredTools, body: body)
    }

    private static func validToolName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }
}
