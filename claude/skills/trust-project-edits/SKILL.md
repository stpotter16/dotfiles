---
name: trust-project-edits
description: Bootstrap a personal, per-project permission rule that auto-approves file Edit/Write calls anywhere under the current project's root, without prompting — and interview the user on an optional personal PostToolUse hook (e.g. auto-format on edit) to go with it. Use when the user asks to "trust" or "stop asking about edits/writes" for the project they're currently in — this is a one-time, per-repo setup they run again in each new project where they want the same behavior. Never applies globally.
---

# Trust Project Edits

Adds an `Edit(**)` allow rule to the **current project's**
`.claude/settings.local.json`, scoped strictly to that project's root and
subdirectories. `Edit(path)` rules are the only permission-rule form the
file-permission check honors, and they cover every file-editing tool
(Edit, Write, NotebookEdit) — a `Write(**)` rule is not matched by the
permission checker at all and will surface as an error the moment a Write
call needs approval. Never add one.

This is personal (gitignored, not shared with teammates) and must be
re-run in each new project where the user wants the same behavior — it
never writes to `~/.claude/settings.json` or any other project.

## Why this shape (not `acceptEdits` mode, not a global setting)

- `permissions.defaultMode: "acceptEdits"` is a blanket, path-agnostic
  session behavior — it isn't confined to the project tree. The user
  specifically wants edits scoped to "this project and its children," so use
  path-pattern rules instead.
- Writing the rule into `~/.claude/settings.json` would NOT achieve
  per-project scoping: relative path patterns in user-scope settings resolve
  against `~/.claude`, not against whatever directory a future session
  happens to run in. Path-scoped trust can only be expressed per-project.
- `.claude/settings.local.json` (not `.claude/settings.json`) keeps this a
  personal preference — it's gitignored by convention and shouldn't affect
  teammates opening the same repo.

## Steps

1. **Find the project root.** Run `git rev-parse --show-toplevel` if inside a
   git repo; otherwise use the current working directory. All paths below
   are relative to this root.

2. **Read before writing.** Read `<root>/.claude/settings.local.json` if it
   exists. If it doesn't, you'll create it fresh — check whether
   `<root>/.claude/` exists first so you know whether to create the
   directory too.

3. **Merge, don't replace.** Add `"Edit(**)"` to `permissions.allow`,
   preserving any existing entries and any other top-level settings already
   in the file. If the file is new, its content is just:
   ```json
   {
     "permissions": {
       "allow": ["Edit(**)"]
     }
   }
   ```
   Skip adding it if it's already present (idempotent — safe to re-run). If
   a stray `"Write(**)"` entry is already in the array (e.g. from before
   this rule was fixed), remove it while you're in there — it does nothing
   but produce a permission-check error.

4. **Ensure it's gitignored.** Check `<root>/.gitignore` for a pattern that
   already covers `.claude/settings.local.json` (e.g. `.claude/settings.local.json`,
   `.claude/*.local.json`, or a broad `.claude/`). If nothing covers it, append
   `.claude/settings.local.json` to `.gitignore` (create the file if it
   doesn't exist). Skip this step if the project isn't a git repo.

5. **Validate.** Run:
   ```
   jq -e '.permissions.allow | index("Edit(**)")' <root>/.claude/settings.local.json
   ```
   Exit 0 with a non-null index confirms the rule is present and the JSON
   is valid.

6. **Offer a personal PostToolUse hook.** Trusting edits and wanting them
   auto-formatted or auto-verified tend to go together, so ask — every run,
   not just the first — via `AskUserQuestion`:

   - **Format/lint on every edit (Recommended)** — auto-detect this
     project's toolchain and suggest a concrete default: an npm/yarn/pnpm
     `lint`/`format` script from `package.json` (picked by lockfile), `ruff
     format`/`black` + `pyproject.toml`, `cargo fmt` + `Cargo.toml`, `gofmt
     -w`/`goimports -w` + `go.mod`, etc. If nothing recognizable is found,
     ask the user directly for the command rather than guessing one.
   - **Something else** — let the user describe a custom command (e.g. a
     test run, a type-check) via the question's free-text option.
   - **No hook** — permission rule only, skip this entirely.

   If the user picks "no hook," stop here and go to Step 7. Otherwise,
   follow the `update-config` skill's hook-construction procedure in full —
   this is a new executable command being wired into every future Edit/Write
   in this project, and deserves the same rigor as any other hook, not a
   shortcut just because it lives in a skill about permissions:

   1. **Dedup check** — read `<root>/.claude/settings.local.json`'s
      `hooks.PostToolUse` (if any) for an existing entry matching the
      `Write|Edit` matcher; if one exists, show it and ask whether to keep,
      replace, or add alongside rather than silently duplicating.
   2. **Construct the command for this project** — using the detected (or
      user-supplied) tool, invoked the way this project actually runs it
      (its lockfile's package manager, a venv-relative binary, etc.), safely
      extracting the file path from the hook's stdin JSON (`jq -r` into a
      quoted variable, never an unquoted `| xargs`).
   3. **Pipe-test the raw command** against a real file from this project
      before wrapping it in any error suppression:
      `echo '{"tool_name":"Edit","tool_input":{"file_path":"<a real file>"}}' | <cmd>`.
      Fix and retest on failure; once it works, wrap with `2>/dev/null ||
      true` (unless the user wants a blocking check instead).
   4. **Write the JSON** — merge a `Write|Edit` `PostToolUse` entry into
      `<root>/.claude/settings.local.json`, the same personal file as the
      permission rule. Never the project's shared `.claude/settings.json` —
      this skill's whole premise is personal-only, and a hook is no
      exception.
   5. **Validate**:
      `jq -e '.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[] | select(.type == "command") | .command' <root>/.claude/settings.local.json`.
   6. **Prove it fires** — temporarily prefix the configured command with a
      sentinel (`echo "$(date) hook fired" >> /tmp/claude-hook-check.txt; `),
      trigger it with a real Edit in this project, confirm the sentinel file
      grew, then revert the prefix and delete the sentinel file. If proof
      fails but the pipe-test and `jq -e` both passed, the settings watcher
      likely isn't watching this file yet (it was created after this
      session started) — tell the user to open `/hooks` once or restart,
      rather than treating it as broken.

7. **Report back.** Tell the user which file was written, that it's
   personal-only (gitignored) and scoped to this project, and that they
   should invoke this skill again in any other project where they want the
   same behavior. Mention `/permissions` as where they can review or revoke
   the rule later, and `/hooks` for the PostToolUse hook if one was added
   this run.

## Common mistakes to avoid

- **Don't add a `Write(**)` rule.** It looks like it should exist by analogy
  with `Edit(**)`, but the permission checker only matches `Edit(path)`
  rules — `Edit(**)` already covers Write and NotebookEdit calls too. A
  `Write(**)` entry is simply dead weight that errors out instead of
  approving anything.
- Don't set `permissions.defaultMode` — that's a different, broader
  mechanism the user explicitly did not choose.
- Don't touch `.claude/settings.json` (shared/committed) or
  `~/.claude/settings.json` (global) — this skill is local-only, by design.
- Don't clobber an existing `permissions.allow` array or unrelated keys in
  `settings.local.json` — always merge.
- Don't skip the pipe-test/validate/prove-it-fires sequence for the
  optional PostToolUse hook just because the rest of this skill is a quick
  permission tweak — a hook runs an arbitrary command on every future edit,
  a materially bigger risk than a permission rule, and earns the same rigor
  `update-config` applies to any other hook.
- Don't write the hook to `.claude/settings.json` — same personal-only rule
  as the permission entry.
