import Foundation

public enum LoopStudioServer {
    /// The standard server: all standard tools, bound to one project session.
    public static func make(session: ProjectSession = ProjectSession()) -> MCPServer {
        MCPServer(instructions: StandardTools.instructions,
                  registry: StandardTools.registry(session: session),
                  resources: StandardTools.resources(session: session))
    }
}
