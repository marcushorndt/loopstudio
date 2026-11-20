# Notes for coding agents

`README.md` describes the app, `docs/architecture.md` maps the code and the realtime rules, and
`docs/mcp.md` describes the MCP server. Run `swift test` before a pull request.

## AI skills (served through the MCP)

- The skills for agents live in `skills/<name>/SKILL.md` (Agent Skills format: `name`, `description`,
  `metadata.updated`). The `EmbedSkills` build plugin compiles them into `LoopStudioControl`, so the
  `loopstudio` tool and the app serve them as the read-only MCP tools `list_skills` and `get_skill`.
  Nothing on disk ships beside the binary.
- A change to an MCP tool (name, arguments, a new guard), a command of `command_apply`, a resource, a
  CLI command of `loopstudio`, or a flow the skills describe (modes, save, bounce, the Patch language)
  updates the matching skill in the same commit. Set `metadata.updated` to the date of the change.
- A new process that an agent can run through the MCP gets a skill, or a section in an existing one.
- `Tests/LoopStudioControlTests/SkillTests.swift` checks the skills: valid frontmatter, every tool and
  command a skill names exists, the patch texts compile, the binary embeds the files on disk, unsafe
  names find nothing. Run `swift test --filter SkillTests`.
- A skill never holds a secret or a private path. Name the environment variable (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`), never its value. The repository is public: write for any user of the app.
