import Foundation

public enum LoopStudioServer {
    /// The standard server: all standard tools, bound to one project session. `extraTools` adds the tools
    /// only a front end has (the app: transport and launches); `note` goes into the instructions.
    /// `skills` serves the skills (`list_skills`, `get_skill`); the default is the set compiled into the binary.
    public static func make(session: any EditSession = ProjectSession(), extraTools: [Tool] = [], note: String = "",
                            skills: SkillCatalog = .builtIn) -> MCPServer {
        var registry = StandardTools.registry(session: session)
        for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
        for tool in skills.tools() { registry.add(tool) }
        for tool in extraTools { registry.add(tool) }
        var instructions = SkillCatalog.instructions + "\n" + StandardTools.instructions + "\n" + StandardTools.namedToolsNote
        if !note.isEmpty { instructions += "\n" + note }
        return MCPServer(instructions: instructions, registry: registry, resources: StandardTools.resources(session: session))
    }
}
