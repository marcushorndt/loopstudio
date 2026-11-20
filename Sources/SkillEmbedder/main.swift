import Foundation

// Writes skills/<name>/SKILL.md into a Swift file, so every binary that links LoopStudioControl (the
// `loopstudio` tool, the app, the tests) carries its skills with no resource bundle beside it.
// The EmbedSkills build plugin runs it at every build: skill-embedder <skills folder> <output .swift file>.
//
// Only a folder with a safe name counts, and only a SKILL.md whose real path lies inside the skills
// folder: a symlink that points out of it is left out.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: skill-embedder <skills folder> <output .swift file>\n".utf8))
    exit(2)
}
let folder = arguments[1], output = arguments[2]

func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func isSafe(_ name: String) -> Bool {
    // ^[a-z0-9]+(?:-[a-z0-9]+)*$ : lowercase letters, digits and single dashes inside.
    let parts = name.split(separator: "-", omittingEmptySubsequences: false)
    return !name.isEmpty && parts.allSatisfy { part in
        !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}

var skills: [(name: String, base64: String)] = []
if let root = realPath(folder) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    for name in names where isSafe(name) {
        let file = root + "/" + name + "/SKILL.md"
        var isDirectory: ObjCBool = false
        guard let real = realPath(file), real.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = FileManager.default.contents(atPath: real) else {
            if FileManager.default.fileExists(atPath: file) {
                FileHandle.standardError.write(Data("warning: skills/\(name)/SKILL.md is not a file inside skills/; left out\n".utf8))
            }
            continue
        }
        skills.append((name, data.base64EncodedString()))
    }
    for name in names where !isSafe(name) && !name.hasPrefix(".") {
        FileHandle.standardError.write(Data("warning: skills/\(name): not a valid skill name (lowercase, digits, dashes); left out\n".utf8))
    }
}

var text = """
// Generated at build time by the EmbedSkills plugin from skills/<name>/SKILL.md. Do not edit.

enum EmbeddedSkills {
    /// Skill name to the base64 of its SKILL.md.
    static let base64: [String: String] = [

"""
if skills.isEmpty { text += "        :\n" }
for skill in skills { text += "        \"\(skill.name)\": \"\(skill.base64)\",\n" }
text += "    ]\n}\n"

// Write only when the text changed, so an unchanged skill does not rebuild the module.
if (try? String(contentsOfFile: output, encoding: .utf8)) != text {
    do { try text.write(toFile: output, atomically: true, encoding: .utf8) }
    catch {
        FileHandle.standardError.write(Data("error: cannot write \(output): \(error)\n".utf8))
        exit(1)
    }
}
