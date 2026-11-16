# Compatibility and acceptance

This is an experimental connected-workflow preview, not complete P0 support
for ordinary unwrapped Codex CLI sessions. Source deployment target macOS 14
is not evidence that older macOS releases or Intel have been accepted.

## Tested scope

| Area | Evidence and boundary |
| --- | --- |
| Platform | Apple Silicon; two Macs on macOS 27.2.1, iTerm2 3.7.7; native Codex 0.169.0 only |
| Automated state/helper checks | 172 Swift tests and 11 isolated executable checks on the development host; no raw conversation content |
| Package maintenance | Actual signed app install, update, app-only rollback, failure restoration and safe refusal checks |
| Startup/filtering | Saved bridge startup, duplicate receiver refusal, process exit/hangup filtering with unresolved records preserved |
| Native return | Owner-confirmed registered-source Spaces/window/tab/split/full-screen/multiple-display cases on the primary host; these do not establish ordinary CLI origin |
| Second Mac | Owner-confirmed real automatic visible notification and exact original terminal return, after Do Not Disturb was disabled; exact source/readback audit agreed |
| Second-Mac cleanup | Test Codex exited, bindings disconnected and list emptied; owned test receiver and bounded QA backend stopped |
| Pictures | Clearly labeled native sample renders only |

The second-Mac QA dependency and its temporary backend are not bundled product
services. Account and native permission steps were owner performed. Ordinary
Codex/backend installation remains a separate prerequisite.

## Known limitations

- Ordinary unwrapped CLI source identity is unresolved. Hooks alone cannot enable
  exact return using an inherited-but-unverified terminal GUID.
- Some ordinary-chat question/approval lifecycle transitions remain unknown.
  Queue acceptance, review and actual resolution are separate. Early permission
  activity does not prove a human is waiting.
- A turn-stop observation does not prove final task completion.
- System Focus, permissions and display-sharing policy affect visible alerts.
- Full keyboard/VoiceOver/long-name/contrast/reduced-motion and sustained workload
  acceptance are incomplete. No production-support SLA or universal platform claim.
- Snapshot retention/migration and broad long-duration capacity gates remain open;
  no automatic history-deletion policy has been enabled.
- Ten-minute empty-receiver measurement on an earlier bounded-read build had
  mean/max RSS 76.77/82.58 MiB and CPU 0.545%. The original all-sampled RSS below
  80 MiB target failed. Current-candidate measurement is reported separately,
  without deleting that failure or changing sampling rules.
- Ad-hoc signature only, no Developer ID/notarization, no automatic updater.

Tests, OS submission acceptance and synthetic events do not prove visible UI,
real-agent lifecycle semantics or complete ordinary-CLI support. No old failure
is promoted to Pass merely because a later scoped check succeeds.
