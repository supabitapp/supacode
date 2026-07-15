nonisolated enum HermesCLISkillContent {
  static let skillMd = """
    ---
    name: \(CLISkillContent.skillName)
    description: \(CLISkillContent.description)
    ---

    # Supacode CLI

    Control Supacode from Hermes. The `supacode` command is available in all Supacode terminal sessions.

    ## Critical ID Tracking

    Never call `supacode tab new` or `supacode surface split` without capturing the UUID printed to stdout.
    The environment variables `SUPACODE_TAB_ID` and `SUPACODE_SURFACE_ID` refer to your current shell, not to
    resources you create later.

    ```sh
    TAB_ID=$(supacode tab new --title "server" -i "npm start")
    SPLIT_ID=$(supacode surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")
    supacode tab rename -t "$TAB_ID" --title "app"
    supacode surface close -t "$TAB_ID" -s "$SPLIT_ID"
    supacode tab close -t "$TAB_ID"
    ```

    Commands: `supacode worktree`, `supacode tab`, `supacode surface`, `supacode repo`, `supacode settings`,
    and `supacode socket`. Use `list` commands to discover IDs, then pass them explicitly with `-w`, `-t`,
    `-s`, `-r`, or `-c`.
    """
}
