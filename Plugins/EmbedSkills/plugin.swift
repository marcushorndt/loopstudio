import Foundation
import PackagePlugin

/// Embeds skills/<name>/SKILL.md into the target as Swift source (`EmbeddedSkills`). The skills then ship
/// inside every binary: the installed app and the `loopstudio` tool serve them with no file beside them.
@main
struct EmbedSkills: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let skills = context.package.directoryURL.appending(path: "skills")
        let output = context.pluginWorkDirectoryURL.appending(path: "EmbeddedSkills.swift")
        // The folder and every SKILL.md are inputs: an edit, a new skill or a removed one runs the tool again.
        var inputs = [skills]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skills.path)) ?? []
        for name in names.sorted() {
            let file = skills.appending(path: name).appending(path: "SKILL.md")
            if FileManager.default.fileExists(atPath: file.path) { inputs.append(file) }
        }
        return [.buildCommand(
            displayName: "Embed the AI skills from skills/",
            executable: try context.tool(named: "SkillEmbedder").url,
            arguments: [skills.path, output.path],
            inputFiles: inputs,
            outputFiles: [output])]
    }
}
