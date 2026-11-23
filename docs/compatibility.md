# Compatibility and acceptance

Cueport alpha.4 is an experimental explicit connected launch/resume release. Ordinary
unwrapped Codex is not automatically attached. Its release scope was explicitly
accepted with incomplete native checks; a waiver never changes a failure into
Pass. See [current evidence](quality.md) and [historical alpha.2 evidence](quality-alpha2.md).

| Area | Scope |
| --- | --- |
| Platform | Apple Silicon; development and Air machines on macOS27.2.1/iTerm2 3.7.7. Other versions/Intel are unqualified. |
| Native dependency | Exact arm64 0.169.0 / 0.170.0 accepted by the helper; both versions passed prior empty-home protocol checks on both Macs; brand-change native model trials were not repeated. |
| Backend | A separately initialized, complete official Codex backend with normal account/network prerequisites; single-binary downloads do not supply it. |
| Recovery | Eight authenticated replacement attempts within120s per incident, stable60s resets budget, no task/approval replay. Peer, process birth, foreground TTY and exact unique terminal remain mandatory. |
| Local notifications | Historical alpha.3: five accurate returns, one safe refusal. Alpha.4 native model trials not repeated; no thirty-success claim. |
| Air notifications | Current-candidate native check incomplete after missing-backend repair. Historical alpha.1/alpha.2 checks are not current acceptance. |
| Resource gate | Exact alpha.4 empty receiver:121samples/600.037s, peak78.891MiB, CPU0.04500%. Separate alpha.3 12-hour results are in [quality evidence](quality.md). |
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
