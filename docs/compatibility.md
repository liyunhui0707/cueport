# Compatibility and acceptance

Cueport alpha.8 supports explicit connected launch and resume. Start or resume a session with the command in Settings to register its iTerm2 pane. See [quality evidence](quality.md) for the scope of the checks.

| Area | Scope |
| --- | --- |
| Platform | Apple Silicon; development and Air machines on macOS27.2.1/iTerm2 3.7.7. Other versions/Intel are unqualified. |
| Native dependency | Native arm64 Codex 0.169.0 or 0.170.0, plus newer stable clients that pass the local protocol check. Version 0.172.0 passed isolated initialization, ephemeral thread creation and unsubscribe in this release. |
| Backend | A separately initialized, complete official Codex backend with normal account/network prerequisites; single-binary downloads do not supply it. |
| Recovery | Eight authenticated replacement attempts within120s per incident, stable60s resets budget, no task/approval replay. Peer, process birth, foreground TTY and exact unique terminal remain mandatory. |
| Local notifications | Historical alpha.3: five accurate returns, one safe refusal. Alpha.4 native model trials not repeated; no thirty-success claim. |
| Air notifications | Current-candidate native check incomplete after missing-backend repair. Historical alpha.1/alpha.2 checks are not current acceptance. |
| Resource gate | See the artifact receipt attached to each release for its own memory and CPU measurements. |
| Native UI | Cueport Settings/version/menu and synthetic light/dark views checked; Dock/reopen and full current-release accessibility/Spaces matrices incomplete. |
| Data/tools | Synthetic stopped-profile migration and recoverable unused-build cleanup checks pass; never overwrite a live/newer profile or restore stale data with app rollback. |
| Signing | Ad-hoc only; no Developer ID/notarization or automatic app updater. |

Missing, conflicting, stale, changed or closed origins fail visibly without title,
project, active-pane or input fallback. A safe refusal remains a failed return.
Execution and outstanding requests remain independent; queue delivery, review,
actual answer/cancellation and unknown are different states. Some native
question/approval resolution remains unconfirmed. A turn-stop reminder does
not prove final task completion; Focus and other OS policies can suppress alerts.

macOS14 is a deployment target rather than a tested support claim. No production
SLA, universal native lifecycle or whole-product P0 guarantee is made. Stored
metadata is local; no prompts/code/tool commands/question bodies or transcript
paths are persisted. No telemetry, automatic approvals or terminal input writer
is implemented.
