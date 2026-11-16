# Install, connect, update and roll back

This first channel is an experimental macOS arm64 preview. The app is ad-hoc
signed, not Developer ID signed or notarized. Codex/iTerm2, credentials and native
backend services are not bundled. Review [compatibility](compatibility.md).

## Download and first open

Download the exact selected release app archive and `SHA256SUMS` from the [selected release](https://github.com/liyunhui0707/agent-attention-router/releases/tag/v0.1.0-alpha.1). Verify the archive against that release's digest:

```sh
shasum -a 256 AgentAttentionRouter-0.1.0-alpha.1-macos-arm64.zip
```

Compare its complete result with the published checksum. A checksum establishes
byte integrity, not publisher identity or product correctness. Extract the app
and keep it at `~/Applications/Agent Attention Router.app`.

macOS may block an app without Developer ID/notarization. If you have reviewed
and trust this source, use the normal macOS Privacy & Security first-open flow
and decide whether to open it yourself. See [Apple’s first-open guidance](https://support.apple.com/102445). Do not disable Gatekeeper, remove
quarantine attributes, reset permissions or paste a bypass command. You can
instead build the app locally from the published source.

The app and its helper run without the source checkout, Swift, Node or Python.
Python 3 is needed only for the optional reviewed installer below.

## External prerequisites

- Apple Silicon Mac, tested macOS 27.2.1; iTerm2 3.7.7 at `/Applications/iTerm.app`.
- Native arm64 Codex **0.169.0**, normally initialized and able to run through its
  own working backend/account/network setup. Other versions and wrappers fail.
- The default native file is expected at
  `/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`.
  The app does not install or upgrade this dependency for you. Official version assets are available from [OpenAI’s 0.169.0 release](https://github.com/openai/codex/releases/tag/rust-v0.169.0); a manually selected native file still needs normal Codex/backend setup.
- Enable iTerm2's Python API through normal settings if you choose to use this
  integration. Review native API/Automation prompts yourself. Do not grant an
  unrelated SSH controller permission to operate your terminal.

Check the file/version and iTerm utility without starting a conversation:

```sh
'./Agent Attention Router.app/Contents/MacOS/aar' check-bridge-dependencies
```

For an explicitly selected native file, add `--native-codex /absolute/path/codex`
to that check, or before the `--` separator in a copied helper launch command.
It must still be a native arm64 file of the exact version. Settings copy buttons
use the default path above; selecting a file in a command does not change them.

This check does not verify backend readiness, login, connectivity or API
permission. A fresh isolated `CODEX_HOME` without a backend can fail WebSocket
upgrade. The app never bootstraps, installs or restarts Codex's managed daemon
or updater. Complete normal Codex setup before retrying a connected launch.

## Connect a project

1. Open the installed app, then Settings → Your connection → Opening the app.
2. On a clean installation, select **Set up connected bridge…**. It prepares
   `~/Library/Application Support/AgentAttentionRouter-Bridge` privately and saves
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
python3 manage_install.py --app './Agent Attention Router.app'
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

A remembered custom data folder stays in place, including an older development
folder inside a checkout. Do not delete it or its containing checkout until a
separately planned migration. A new installation uses Application Support.

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
| Dependency/version failure | Check the exact native path/0.169.0 version; do not substitute a shell or npm wrapper. |
| WebSocket handshake/reconnect failure | Check normal Codex backend availability separately from model networking. |
| No visible alert | Check app authorization, desktop alert style, Focus and display-sharing policies. A Notification Center record and OS submission acceptance are distinct from visible display. |
| Cannot return | Keep the original pane/process open and review iTerm API permission. No title/project fallback is used. |
| Question persists | Reviewed does not mean answered; unknown resolution is retained deliberately. |
| Extra empty TEST icon | Close the explicit test receiver; keep the daily app. Test data and identity are separate. |
