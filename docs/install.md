# Install, connect, update and roll back

This first channel is an experimental macOS arm64 preview. The app is ad-hoc
signed, not Developer ID signed or notarized. Codex/iTerm2, credentials and native
backend services are not bundled. Review [compatibility](compatibility.md).

## Download and first open

Download the exact selected release app archive and `SHA256SUMS` from the [Releases](https://github.com/liyunhui0707/cueport/releases). Verify the archive against that release's digest:

```sh
shasum -a 256 Cueport-0.1.0-alpha.4-macos-arm64.zip
```

Compare its complete result with the published checksum. A checksum establishes
byte integrity, not publisher identity or product correctness. Extract the app
and keep it at `~/Applications/Cueport.app`.

macOS may block an app without Developer ID/notarization. If you have reviewed
and trust this source, use the normal macOS Privacy & Security first-open flow
and decide whether to open it yourself. See [Apple’s first-open guidance](https://support.apple.com/102445). Do not disable Gatekeeper, remove
quarantine attributes, reset permissions or paste a bypass command. You can
instead build the app locally from the published source.

The app and its helper run without the source checkout, Swift, Node or Python.
Python 3 is needed only for the optional reviewed installer below.

## External prerequisites

- Apple Silicon Mac, tested macOS 27.2.1; iTerm2 3.7.7 at `/Applications/iTerm.app`.
- Native arm64 Codex **0.169.0 or 0.170.0**, normally initialized and able to run through its
  own working backend/account/network setup. Other versions and wrappers fail.
  A single native executable is not a complete managed-backend installation.
  If the official backend socket is absent, install/initialize a complete official
  Codex package separately; repeated connected launches cannot repair it.
- The default native file is expected at
  `/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`.
  The app does not install or upgrade this dependency for you. Official version assets are available from [OpenAI’s 0.169.0 release](https://github.com/openai/codex/releases/tag/rust-v0.169.0); a manually selected native file still needs normal Codex/backend setup.
- Enable iTerm2's Python API through normal settings if you choose to use this
  integration. Review native API/Automation prompts yourself. Do not grant an
  unrelated SSH controller permission to operate your terminal.

Check the file/version and iTerm utility without starting a conversation:

```sh
'./Cueport.app/Contents/MacOS/cueport' check-bridge-dependencies
```

For an explicitly selected native file, add `--native-codex /absolute/path/codex`
to that check, or before the `--` separator in a copied helper launch command.
It must still be a native arm64 file of a reviewed exact version. Settings also offers
**Choose native file…** and **Check file/version**; a successfully checked choice
is used by future copied commands. A path supplied only to one CLI command does
not change the saved Settings choice or existing clients.

This check does not verify backend readiness, login, connectivity or API
permission. A fresh isolated `CODEX_HOME` without a backend can fail WebSocket
upgrade. The app never bootstraps, installs or restarts Codex's managed daemon
or updater. Complete normal Codex setup before retrying a connected launch.

## Connect a project

1. Open the installed app, then Settings → Your connection → Opening the app.
2. On a clean installation, select **Set up connected bridge…**. It prepares
   `~/Library/Application Support/Cueport-Bridge` privately and saves
   the next startup choice. Quit and reopen the app; confirm Connected bridge.
3. Use **Copy launch command** for a new conversation. Use **Copy resume command**
   for an existing project, then select its original conversation in the native
   picker. Run the command in an iTerm2 Shell from the actual project directory.
   Empty-query Esc in the native picker starts a new conversation; Ctrl+C exits.
4. Complete native login/trust/API dialogs yourself. Enable notifications in the
   app and macOS. Focus/Do Not Disturb and display-sharing policies can suppress
   visible alerts; the app does not bypass them.
5. Handle questions and approvals in Codex. Clicking a reminder reviews it;
   it does not submit an answer or approval.

Already-running unwrapped Codex windows are not attached retrospectively.
Closing/exiting a registered source removes it from the main panel; history is
retained without inventing request resolution. Archive/restore is in Diagnostics.

## Reviewed optional installer

Keep `manage_install.py` beside the extracted app. Start with a review:

```sh
python3 manage_install.py --app './Cueport.app'
```

Review the destination and complete candidate fingerprint. Quit only the receiver
at the destination; registered Codex clients may stay open. Re-run with `--apply`
and `--expected-fingerprint` followed by the exact reviewed fingerprint.
The installer validates bundle/signature, stages new inodes and retains the
previous app under `~/Applications/.AttentionRouter Backups/`. It refuses changed
input, symlinks and an active destination receiver. It neither edits preferences
nor starts an app or copies/restores session data.

Existing workers keep their mapped helper through an update. Reconnect naturally
when their work is idle to load a changed helper. The receiver's Diagnostics
compares loaded and on-disk builds; an update is not a worker restart.

A remembered custom data folder stays in place. For an old development folder,
first finish and exit all its connected Codex clients, quit its receiver, then
review a stopped-profile migration:

```sh
python3 manage_bridge_data.py --source /absolute/old-profile --destination /absolute/new-profile --helper './Cueport.app/Contents/MacOS/cueport'
```

Only apply after the native preflight reports zero clients/workers/unknown
tickets, using `--apply --expected-fingerprint` with that exact reviewed value.
The tool requires a new destination, retains all original data, verifies the
copy, remembers the new location and marks the old profile as relocated.
It never overwrites a newer profile or restores an old snapshot. Keep the receipt
and original folder. A failed activation leaves copies for explicit review.
A new installation uses Application Support.

## Update source and connection recovery

The selected global npm installation carries the official npm update context;
a real Homebrew cask uses Homebrew. An independently downloaded native file
uses manual update guidance and hides the package-manager update popup only for
that connected invocation. No global Codex config is changed. Recheck the selected
native path/version after changing a dependency; existing clients retain theirs.

A transient transport loss keeps the listener for the same live TUI and admits
only freshly authenticated replacements. Retries are bounded to eight attempts
within 120 seconds per incident; a stable connection resets the budget. The app
never resubmits a task, answer or approval. Missing/changed/closed identity fails
visibly. Pending requests remain unconfirmed until real evidence arrives again.
A matching previously observed active turn may be recovered from explicit native
resume metadata; its timestamp is observation time, not model completion time.

If recovery fails, save any draft, exit that native client yourself, and use
**Copy resume command** from the installed app in your project directory. Old
temporary socket commands can be obsolete. Reopening the receiver alone cannot
repair a missing official backend, login or model network connectivity.

## Rollback and recovery

Pass the exact retained previous app from the install receipt as `--app` to the
same reviewed installer. Quit the destination receiver, apply the reviewed
fingerprint and reopen the installed path. Rollback changes app files only;
never replace current session data with an older snapshot.

Verification failures restore the old app and retain the failed payload.
A machine/process crash between directory moves may leave the target absent;
the retained old app remains in the dated backup folder. Inspect that exact
bundle and use it for recovery. Backups are not silently pruned. Finder copy is
an alternative when all mapped clients are closed and an old-app backup is kept.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No projects | Confirm Connected bridge and use the copied launcher/resume command; existing unwrapped clients are not auto-discovered. |
| Dependency/version failure | Check the exact native path and reviewed 0.169.0/0.170.0 version; do not substitute a shell or npm wrapper. |
| WebSocket handshake/reconnect failure | Check normal Codex backend availability separately from model networking. |
| No visible alert | Check app authorization, desktop alert style, Focus and display-sharing policies. A Notification Center record and OS submission acceptance are distinct from visible display. |
| Cannot return | Keep the original pane/process open and review iTerm API permission. No title/project fallback is used. |
| Question persists | Reviewed does not mean answered; unknown resolution is retained deliberately. |
| Extra empty TEST icon | Close the explicit test receiver; keep the daily app. Test data and identity are separate. |


## Upgrade from Agent Attention Router

Cueport keeps the existing application identity, preferences and stored sessions.
For the first name change, save drafts and finish tasks, manually exit the old
connected clients, then quit the old receiver. Keep ordinary unrelated Codex
sessions open. Preview the reviewed installer with the old sibling app specified:

```sh
python3 manage_install.py --app './Cueport.app' --rename-from "$HOME/Applications/Agent Attention Router.app"
```

Apply only after reviewing its candidate fingerprint, by adding `--apply
--expected-fingerprint` and that exact value to the same command. Active old
helpers or an existing conflicting Cueport destination stop the rename. The old
app is retained in `~/Applications/.Cueport Backups`; current session data and
preferences are never rolled back. `aar` remains a packaged compatibility alias;
new copied commands use `Cueport.app/Contents/MacOS/cueport`.

Existing remembered bridge folders are kept. A new setup uses
`~/Library/Application Support/Cueport-Bridge`. Moving a development-folder
profile is a separate stopped-profile operation with a reviewed fingerprint;
never copy a stale backup over current data. Old release assets retain their
original names and checksums.


Configured global Codex Hooks are also application dependencies. If a Hook still
references an old app/helper, the first-name-change installer refuses the rename,
and the recoverable cleanup tool retains it even when no process is running.
Keep that old dependency until its Hook command is separately reviewed/moved
through the normal Codex Hook workflow. The tools do not rewrite Hook commands
or trust settings. Custom Hook sources outside the default global hooks.json
still require explicit review; never delete an old executable merely because
its terminal windows are closed.

## Names used by existing installations

The daily application is `Cueport.app`. Use its packaged `Contents/MacOS/cueport`
helper for new integrations. The `aar` executable remains available to existing
scripts. Moving a source checkout while Codex Hooks point into its build folder
can produce exit 127. Keep the old helper available during migration, back up the
Hook configuration, replace only the owned executable paths, and review the new
command through Codex's normal Hook trust flow.

The historical bundle identifier, preference and protocol keys preserve existing
settings and data. A separately installed Codex dependency may still live under
`Application Support/AgentAttentionRouter`. Keep it while a selected executable
uses that path. Earlier release assets keep their original filenames.
