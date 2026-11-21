import Foundation

public enum LoopStudioServer {
    /// The standard server: all standard tools, bound to one project session. `extraTools` adds the tools
    /// only a front end has (the app: transport and launches); `note` goes into the instructions.
    public static func make(session: any EditSession = ProjectSession(), extraTools: [Tool] = [], note: String = "") -> MCPServer {
        var registry = StandardTools.registry(session: session)
        for tool in StandardTools.namedTools(session: session) { registry.add(tool) }
        for tool in StandardTools.noteTools(session: session) { registry.add(tool) }
        for tool in extraTools { registry.add(tool) }
        var instructions = StandardTools.instructions + "\n" + StandardTools.namedToolsNote + "\n" + StandardTools.noteToolsNote
        if !note.isEmpty { instructions += "\n" + note }
        return MCPServer(instructions: instructions, registry: registry, resources: StandardTools.resources(session: session))
    }
}
