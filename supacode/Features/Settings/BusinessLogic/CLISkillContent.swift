/// Content for the Supacode CLI skill installed into coding agent configs.
nonisolated enum CLISkillContent {
  static let skillName = "supacode-cli"

  static let description =
    "Control Supacode from the terminal."
    + " Use when running supacode CLI commands, managing worktrees, tabs, and surfaces programmatically,"
    + " or when inside a Supacode terminal session."

  // MARK: - Claude Code.

  static let claudeSkill = """
    ---
    name: \(skillName)
    description: \(description)
    ---

    # Supacode CLI

    Control Supacode from the terminal. The `supacode` command is available in all Supacode terminal sessions.

    ## CRITICAL: ID Tracking

    **NEVER call `supacode tab new` or `supacode surface split` without capturing
    the output.** These commands print the new resource UUID to stdout. You MUST
    capture it into a variable — without it you cannot target the resource afterward.

    **NEVER omit `-t` and `-s` flags when targeting a resource you created.**
    The environment variables `$SUPACODE_TAB_ID` and `$SUPACODE_SURFACE_ID` refer
    to the shell session you are running in, NOT to any tab or surface you created.
    If you omit `-t`/`-s`, the command targets your own shell — not the new resource.

    For new tabs, the initial surface ID equals the tab ID.

    ### Correct pattern — ALWAYS follow this:

    **Run all related commands in a SINGLE Bash call** so captured variables
    are available to subsequent commands. If you split across tool calls,
    variables like `$TAB_ID` will be lost.

    ```sh
    # 1. ALWAYS capture the UUID from tab new / surface split.
    TAB_ID=$(supacode tab new -i "npm start")

    # 2. ALWAYS pass -t and -s explicitly when targeting created resources.
    #    For new tabs: surface ID = tab ID.
    SPLIT_ID=$(supacode surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")

    # 3. ALWAYS use captured IDs for subsequent operations.
    supacode surface focus -t "$TAB_ID" -s "$SPLIT_ID" -i "echo hello"
    supacode surface close -t "$TAB_ID" -s "$SPLIT_ID"
    supacode tab close -t "$TAB_ID"
    ```

    ### WRONG — never do this:

    ```sh
    # BAD: not capturing the UUID — you lose the reference.
    supacode tab new -i "npm start"

    # BAD: missing -t/-s — this targets your own shell, not the new tab.
    supacode surface split -d v -i "npm test"

    # BAD: splitting commands across separate Bash calls — variables are lost.
    # Call 1: TAB_ID=$(supacode tab new)
    # Call 2: supacode surface split -t "$TAB_ID" ...  ← $TAB_ID is empty!
    ```

    ## Environment

    Inside Supacode terminals, these environment variables are set automatically:

    | Variable | Description |
    |----------|-------------|
    | `SUPACODE_WORKTREE_ID` | Current worktree (percent-encoded path). |
    | `SUPACODE_TAB_ID` | Current tab UUID (your shell's tab, not created ones). |
    | `SUPACODE_SURFACE_ID` | Current surface UUID (your shell's surface, not created ones). |
    | `SUPACODE_REPO_ID` | Current repository (percent-encoded path). |
    | `SUPACODE_SOCKET_PATH` | Socket for app communication. |

    `-w`, `-t`, `-s`, `-r` default to these when omitted. This is only useful for
    targeting **your own** session. For anything you create, pass explicit IDs.

    ## Commands

    ### App

    ```
    supacode                          # Bring Supacode to front.
    supacode open                     # Same as above.
    ```

    ### Worktree

    ```
    supacode worktree list [-f]                   # List worktree IDs (-f = focused only).
    supacode worktree focus [-w <id>]            # Focus worktree.
    supacode worktree run [-w <id>]              # Run the worktree script.
    supacode worktree stop [-w <id>]             # Stop the running script.
    supacode worktree archive [-w <id>]          # Archive worktree.
    supacode worktree unarchive [-w <id>]        # Unarchive worktree.
    supacode worktree delete [-w <id>]           # Delete worktree.
    supacode worktree pin [-w <id>]              # Pin worktree.
    supacode worktree unpin [-w <id>]            # Unpin worktree.
    ```

    ### Tab

    ```
    supacode tab list [-w <id>] [-f]                              # List tab UUIDs in worktree (-f = focused only).
    supacode tab focus [-w <id>] [-t <id>]                      # Focus tab.
    supacode tab new [-w <id>] [-i <cmd>] [-n <uuid>]           # Create new tab (prints UUID to stdout).
    supacode tab close [-w <id>] [-t <id>]                      # Close tab.
    ```

    ### Surface

    ```
    supacode surface list [-w <id>] [-t <id>] [-f]                                              # List surface UUIDs in tab (-f = focused only).
    supacode surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]                         # Focus surface.
    supacode surface split [-w <id>] [-t <id>] [-s <id>] [-i <cmd>] [-d h|v] [-n <uuid>]    # Split (prints UUID to stdout).
    supacode surface close [-w <id>] [-t <id>] [-s <id>]                                     # Close surface.
    ```

    ### Repository

    ```
    supacode repo list                                                     # List repository IDs.
    supacode repo open <path>                                              # Open repository.
    supacode repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch]  # Create worktree.
    ```

    ### Settings

    ```
    supacode settings [<section>]        # Open settings (general|notifications|worktrees|developer|shortcuts|updates|github).
    supacode settings repo [-r <id>]     # Open repository settings.
    ```

    ### Socket

    ```
    supacode socket                      # List active socket paths.
    ```

    ## Flag Reference

    | Flag | Short | Default | Description |
    |------|-------|---------|-------------|
    | `--worktree` | `-w` | `$SUPACODE_WORKTREE_ID` | Worktree ID. |
    | `--tab` | `-t` | `$SUPACODE_TAB_ID` | Tab UUID. |
    | `--surface` | `-s` | `$SUPACODE_SURFACE_ID` | Surface UUID. |
    | `--repo` | `-r` | `$SUPACODE_REPO_ID` | Repository ID. |
    | `--input` | `-i` | — | Command to run in the terminal. |
    | `--direction` | `-d` | `horizontal` | Split direction (`horizontal`/`h` or `vertical`/`v`). |
    | `--id` | `-n` | random | UUID for new tab/surface. |
    """

  // MARK: - Codex.

  // Codex uses SKILL.md (with frontmatter) + AGENTS.md.
  static let codexSkillMd = """
    ---
    name: \(skillName)
    description: \(description)
    version: 1.0.0
    ---

    # Supacode CLI

    Control Supacode from the terminal. The `supacode` command is available in all Supacode terminal sessions.

    ## CRITICAL: ID Tracking

    **NEVER call `supacode tab new` or `supacode surface split` without capturing
    the output.** They print the new UUID to stdout. Without it you cannot target
    the resource afterward.

    **NEVER omit `-t`/`-s` when targeting a created resource.** The env vars point
    to your own shell, not to anything you created.

    For new tabs, surface ID = tab ID.

    ### Correct:

    ```sh
    TAB_ID=$(supacode tab new -i "npm start")
    SPLIT_ID=$(supacode surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")
    supacode surface close -t "$TAB_ID" -s "$SPLIT_ID"
    supacode tab close -t "$TAB_ID"
    ```

    ### WRONG:

    ```sh
    supacode tab new -i "npm start"           # BAD: not captured
    supacode surface split -d v -i "test"     # BAD: missing -t/-s, targets your shell
    ```

    ## Commands

    - `supacode worktree [list [-f]|focus|run|stop|archive|unarchive|delete|pin|unpin] [-w <id>]`
    - `supacode tab [list [-w] [-f]|focus|new|close] [-w <id>] [-t <id>] [-i <cmd>] [-n <uuid>]`
    - `supacode surface [list [-w] [-t] [-f]|focus|split|close] [-w <id>] [-t <id>] [-s <id>] [-i <cmd>] [-d h|v] [-n <uuid>]`
    - `supacode repo [list | open <path> | worktree-new [-r <id>] [--branch] [--base] [--fetch]]`
    - `supacode settings [<section>]`
    - `supacode socket`

    `list` outputs one ID per line (percent-encoded for worktrees/repos, UUIDs for tabs/surfaces).
    Use these IDs directly as `-w`, `-t`, `-s`, `-r` flag values.

    Flags: `-w` (worktree), `-t` (tab), `-s` (surface), `-r` (repo), `-i` (input), `-d` (direction), `-n` (new ID).
    Env var defaults only target your own shell session. Pass explicit IDs for created resources.
    """

  static let codexAgentsMd = """
    # Supacode CLI

    \(description)

    ## CRITICAL: ID Tracking

    **NEVER call `supacode tab new` or `supacode surface split` without capturing
    the output.** They print the new UUID to stdout. Without it you cannot target
    the resource afterward.

    **NEVER omit `-t`/`-s` when targeting a created resource.** The env vars point
    to your own shell, not to anything you created.

    For new tabs, surface ID = tab ID.

    ### Correct:

    ```sh
    TAB_ID=$(supacode tab new -i "npm start")
    SPLIT_ID=$(supacode surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")
    supacode surface close -t "$TAB_ID" -s "$SPLIT_ID"
    supacode tab close -t "$TAB_ID"
    ```

    ### WRONG:

    ```sh
    supacode tab new -i "npm start"           # BAD: not captured
    supacode surface split -d v -i "test"     # BAD: missing -t/-s, targets your shell
    ```

    Flags: `-w` (worktree), `-t` (tab), `-s` (surface), `-r` (repo), `-i` (input), `-d` (direction), `-n` (new ID).
    Env var defaults only target your own shell session. Pass explicit IDs for created resources.
    """
}
