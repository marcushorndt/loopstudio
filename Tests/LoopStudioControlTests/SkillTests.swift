import Foundation
import Testing
@testable import LoopStudioControl
@testable import LoopStudioCore

// The skills in skills/ go to every MCP client (list_skills, get_skill). A skill that names a tool or a
// command the server no longer has sends an agent into an error, so a rename or a removal must update the
// skill in the same commit. These tests fail when it does not.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let skillsFolder = repoRoot.appendingPathComponent("skills")

private func rpc(_ server: MCPServer, _ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
    let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params])
    let data = try #require(await server.handle(Data(message.text.utf8)))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func call(_ server: MCPServer, _ name: String, _ arguments: JSONValue = .object([:])) async throws -> (isError: Bool, data: JSONValue) {
    let response = try await rpc(server, "tools/call", .object(["name": .string(name), "arguments": arguments]))
    let result = try #require(response["result"], "protocol error: \(response.text)")
    return (result["isError"]?.boolValue ?? false, result["structuredContent"] ?? .null)
}

/// Every tool a client can see: the server's own, and the ones only the app adds (read from its source,
/// since the app is an executable target the tests cannot link).
private func allToolNames() async throws -> Set<String> {
    let listed = try await rpc(LoopStudioServer.make(), "tools/list")
    var names = Set((listed["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    let app = try String(contentsOf: repoRoot.appendingPathComponent("Sources/LoopStudioApp/LiveControl.swift"), encoding: .utf8)
    let appTools = app.matches(of: try Regex(#"Tool\(name: "([a-z_]+)""#)).compactMap { $0.output[1].substring.map(String.init) }
    #expect(!appTools.isEmpty, "found no app tools in LiveControl.swift; update this test")
    names.formUnion(appTools)
    return names
}

private func backticked(_ text: String, _ pattern: String) throws -> Set<String> {
    Set(text.matches(of: try Regex("`(" + pattern + ")`")).compactMap { $0.output[1].substring.map(String.init) })
}

@Test func theBuildEmbedsTheSkillsOnDisk() {
    let onDisk = SkillCatalog.load(directory: skillsFolder)
    #expect(!onDisk.skills.isEmpty, "skills/ holds no SKILL.md")
    // A difference means the binary was built from other files than the ones in skills/.
    #expect(SkillCatalog.builtIn.skills == onDisk.skills)
    #expect(SkillCatalog.builtIn.skills.contains { $0.name == "loopstudio-mcp" })
}

@Test func everySkillHasValidFrontmatter() throws {
    let folders = try FileManager.default.contentsOfDirectory(atPath: skillsFolder.path).filter { !$0.hasPrefix(".") }
    let catalog = SkillCatalog.load(directory: skillsFolder)
    #expect(Set(folders) == Set(catalog.skills.map(\.name)), "every folder in skills/ needs a safe name and a SKILL.md")
    for skill in catalog.skills {
        let meta = SkillCatalog.frontmatter(skill.content)
        #expect(meta["name"] == skill.name, "skills/\(skill.name): the frontmatter name must equal the folder name")
        #expect((40...1024).contains(skill.description.count), "skills/\(skill.name): the description says what and when, 40 to 1024 characters")
        #expect(skill.updated?.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, "skills/\(skill.name): metadata.updated is a date")
        #expect(skill.content.split(separator: "\n").count <= 160, "skills/\(skill.name) is too long; split it")
    }
}

/// A backticked word in snake_case is a tool name, and so is a backticked single-word tool name.
@Test func everyToolASkillNamesExists() async throws {
    let tools = try await allToolNames()
    var missing: [String] = []
    for skill in SkillCatalog.load(directory: skillsFolder).skills {
        var named = try backticked(skill.content, "[a-z0-9]+(?:_[a-z0-9]+)+")
        named.formUnion(try backticked(skill.content, "undo|redo|transport|launch|show"))
        for tool in named.sorted() where !tools.contains(tool) { missing.append("skills/\(skill.name) names `\(tool)`") }
    }
    #expect(missing.isEmpty, "a skill names a tool the server does not have; update the skill: \(missing)")
}

/// A backticked camelCase word that starts like a command (setVolume, insertDevice ...) must be a command
/// that command_examples shows.
@Test func everyCommandASkillNamesExists() throws {
    let commands = Set(try StandardTools.examples().keys.map { String($0.split(separator: " ")[0]) })
    var missing: [String] = []
    for skill in SkillCatalog.load(directory: skillsFolder).skills {
        let named = try backticked(skill.content, "(?:set|insert|remove|move|add|commit)[A-Z][A-Za-z]*|batch")
        for command in named.sorted() where !commands.contains(command) { missing.append("skills/\(skill.name) names `\(command)`") }
    }
    #expect(missing.isEmpty, "a skill names a command that command_examples does not have; update the skill: \(missing)")
}

@Test func thePatchTextsInTheSkillsCompile() throws {
    for skill in SkillCatalog.load(directory: skillsFolder).skills {
        for block in skill.content.matches(of: try Regex("```\\n(patch \"[^`]*?)```")) {
            let source = try #require(block.output[1].substring.map(String.init))
            guard case .success = PatchCompiler.cached(source) else {
                Issue.record("skills/\(skill.name): a patch text does not compile:\n\(source)")
                continue
            }
        }
    }
}

@Test func noSkillHoldsASecretOrAPrivatePath() {
    let secret = /sk-ant-[A-Za-z0-9_-]{10,}|sk-proj-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|-----BEGIN/
    for skill in SkillCatalog.load(directory: skillsFolder).skills {
        #expect(skill.content.firstMatch(of: secret) == nil, "skills/\(skill.name) looks like it holds a key; name the env variable instead")
        #expect(!skill.content.contains("/Users/"), "skills/\(skill.name) holds a home path; write ~ instead")
    }
}

@Test func anUnsafeNameFindsNothing() throws {
    let catalog = SkillCatalog.load(directory: skillsFolder)
    for bad in ["../README", "../skills/loopstudio-mcp", "Loopstudio-mcp", "loopstudio_mcp", "a/b", "", "-x", "x-", "a--b", "loopstudio-mcp\n"] {
        #expect(catalog.skill(named: bad) == nil, "\(bad)")
        #expect(!SkillCatalog.isValidName(bad), "\(bad)")
    }
    #expect(catalog.skill(named: "loopstudio-mcp") != nil)
}

@Test func aSymlinkOutOfTheFolderFindsNothing() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appendingPathComponent("skills"), outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("good"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "---\nname: good\n---\n".write(to: folder.appendingPathComponent("good/SKILL.md"), atomically: true, encoding: .utf8)
    try "---\nname: leak\n---\nsecret".write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("leak"), withDestinationURL: outside)
    let catalog = SkillCatalog.load(directory: folder)
    #expect(catalog.skills.map(\.name) == ["good"])
    #expect(catalog.skill(named: "leak") == nil)
}

/// There are no tokens here: the read-only analogue is that both tools change nothing, need no project, and
/// exist in the file mode and in the app (extra tools join the standard ones). The in-app assistant asks
/// before every tool that is not read-only, so the read-only flag lets it load skills without a question.
@Test func theSkillToolsAreReadOnlyAndAlwaysThere() async throws {
    for server in [LoopStudioServer.make(), LoopStudioServer.make(extraTools: [Tool(name: "app_only", title: "", description: "", inputSchema: Schema.object()) { _ in .null }])] {
        let listed = try await rpc(server, "tools/list")
        let tools = listed["result"]?["tools"]?.arrayValue ?? []
        for name in ["list_skills", "get_skill"] {
            let tool = try #require(tools.first { $0["name"]?.stringValue == name }, "\(name) is missing")
            #expect(tool["annotations"]?["readOnlyHint"]?.boolValue == true)
            #expect(tool["annotations"]?["destructiveHint"]?.boolValue == false)
        }
        let initialize = try await rpc(server, "initialize", .object(["protocolVersion": .string("2025-06-18")]))
        #expect(initialize["result"]?["instructions"]?.stringValue?.contains("call list_skills at the start") == true)

        // No project is open.
        let list = try await call(server, "list_skills")
        #expect(!list.isError)
        let names = (list.data["skills"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("loopstudio-mcp"))
        #expect(list.data["skills"]?.arrayValue?.first?["content"] == nil, "list_skills sends no text")

        let one = try await call(server, "get_skill", .object(["name": .string("loopstudio-mcp")]))
        #expect(!one.isError)
        #expect(one.data["content"]?.stringValue?.contains("name: loopstudio-mcp") == true)

        let bad = try await call(server, "get_skill", .object(["name": .string("../README")]))
        #expect(bad.isError)
    }
}

@Test func theFrontmatterReaderTakesABOMAndCRLF() {
    let text = "\u{FEFF}--- \r\nname: x-y\r\ndescription: \"A skill\"\r\nmetadata:\r\n  updated: 2026-11-20\r\n---\r\nBody"
    #expect(SkillCatalog.frontmatter(text) == ["name": "x-y", "description": "A skill", "updated": "2026-11-20"])
}
