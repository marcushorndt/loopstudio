import Foundation

/// The AI skills of loopstudio: skills/<name>/SKILL.md in the Agent Skills format (YAML frontmatter with
/// name, description and metadata.updated, then the instructions).
///
/// The EmbedSkills build plugin compiles the files into this module (`EmbeddedSkills`), so the installed app
/// and the `loopstudio` tool serve them with nothing on disk beside the binary. The MCP server offers them as
/// the read-only tools `list_skills` and `get_skill`, in the file mode and in the app.
///
/// Rule: a change to a tool, a command or a flow updates the skill that describes it in the same commit.
/// `Tests/LoopStudioControlTests/SkillTests.swift` fails when a skill names a tool or a command that does not
/// exist. A skill never holds a secret.
public struct Skill: Sendable, Equatable {
    public let name: String
    public let description: String
    public let updated: String?
    /// The full SKILL.md text, frontmatter included.
    public let content: String
}

public struct SkillCatalog: Sendable {
    /// A skill name: lowercase letters and digits, single dashes between them (the Agent Skills rule).
    public static let namePattern = "^[a-z0-9]+(?:-[a-z0-9]+)*$"

    /// Sorted by name.
    public let skills: [Skill]

    /// The skills compiled into this binary.
    public static let builtIn = SkillCatalog(texts: EmbeddedSkills.base64.compactMapValues { encoded in
        Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }
    })

    /// Name to SKILL.md text. A name that is not safe is left out.
    public init(texts: [String: String]) {
        skills = texts.filter { Self.isValidName($0.key) }.sorted { $0.key < $1.key }.map { name, text in
            let meta = Self.frontmatter(text)
            return Skill(name: name, description: meta["description"] ?? "", updated: meta["updated"], content: text)
        }
    }

    /// Reads skills/<name>/SKILL.md from a folder, the way the build plugin does: only safe names, and only a
    /// file whose real path lies inside the folder (a symlink out of it finds nothing).
    public static func load(directory: URL) -> SkillCatalog {
        guard let root = realPath(directory.path) else { return SkillCatalog(texts: [:]) }
        var texts: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where isValidName(name) {
            var isDirectory: ObjCBool = false
            guard let file = realPath(root + "/" + name + "/SKILL.md"), file.hasPrefix(root + "/"),
                  FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = FileManager.default.contents(atPath: file) else { continue }
            texts[name] = String(decoding: data, as: UTF8.self)
        }
        return SkillCatalog(texts: texts)
    }

    /// One skill, or nil for an unknown or unsafe name.
    public func skill(named name: String) -> Skill? {
        guard Self.isValidName(name) else { return nil }
        return skills.first { $0.name == name }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let regex = try? Regex(namePattern) else { return false }
        return name.wholeMatch(of: regex) != nil
    }

    /// name, description and metadata.updated from the frontmatter (single-line values).
    public static func frontmatter(_ text: String) -> [String: String] {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        // "\r\n" is one Character in Swift, so split on any newline character. A "---" line may carry spaces.
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: .whitespaces) == "---" ? "---" : String(line)
        }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var out: [String: String] = [:]
        var inMetadata = false
        func value(_ s: Substring) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            return v
        }
        for line in lines[1..<end] {
            let indented = line.first == " " || line.first == "\t"
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...]
            if !indented {
                inMetadata = key == "metadata"
                if key == "name" || key == "description" { out[key] = value(rest) }
            } else if inMetadata, key == "updated" {
                out["updated"] = value(rest)
            }
        }
        return out
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: The MCP tools

extension SkillCatalog {
    /// The sentence for the server instructions.
    public static let instructions = """
    Skills: call list_skills at the start of a session. Before a task that a skill describes, load it with get_skill and follow it.
    """

    /// `list_skills` and `get_skill`. Both are read-only, need no open project, and exist in every mode.
    public func tools() -> [Tool] {
        let catalog = self
        return [
            Tool(
                name: "list_skills", title: "List the skills",
                description: "The skills for agents that work with loopstudio: name, description (what it covers and when to use it) and the date of the last update. No text; get_skill loads one.",
                inputSchema: Schema.object(), annotations: .read
            ) { _ in
                .object(["skills": .array(catalog.skills.map { s in
                    .object(["name": .string(s.name), "description": .string(s.description),
                             "updated": s.updated.map { .string($0) } ?? .null])
                })])
            },
            Tool(
                name: "get_skill", title: "Load a skill",
                description: "The full SKILL.md text of one skill from list_skills. Read it before the task it describes and follow it.",
                inputSchema: Schema.object([
                    "name": .object(["type": .string("string"), "pattern": .string(Self.namePattern),
                                     "description": .string("The skill name from list_skills, such as loopstudio-mcp.")]),
                ], required: ["name"]),
                annotations: .read
            ) { args in
                let name = try args.string("name")
                guard let skill = catalog.skill(named: name) else {
                    let names = catalog.skills.map(\.name).joined(separator: ", ")
                    throw ToolFailure("no skill '\(name)'. Skills: \(names.isEmpty ? "none" : names).")
                }
                return .object(["name": .string(skill.name), "description": .string(skill.description),
                                "updated": skill.updated.map { .string($0) } ?? .null, "content": .string(skill.content)])
            },
        ]
    }
}
