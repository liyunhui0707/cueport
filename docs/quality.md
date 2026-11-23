# Cueport alpha.4 evidence and historical alpha.3 scope

This is an explicit connected-workflow prerelease for native arm64 Codex
0.169.0 / 0.170.0, with an ad-hoc signature. It is not complete P0 acceptance.
The owner explicitly chose to publish with incomplete native acceptance rather
than continue repetitive READY tasks. Incomplete checks below remain incomplete.

## Cueport alpha.4 scope

Alpha.4/build4 is the owner-selected brand and delivery update. Its native C-port
and cue-dot artwork is original. The menu-bar template, app icon, in-app mark,
public filenames and repository are aligned. Historical protocol/bundle IDs and
versioned preference keys intentionally retain compatibility. The `cueport` CLI
is packaged from the same build as the retained `aar` alias, avoiding SwiftPM
case-insensitive product-name collisions with the Cueport receiver.

No new model task or READY test is part of this rename. Historical results below
qualify their actual alpha.3 artifacts, not new alpha.4 native acceptance. The existing 198 Swift +11 CLI +5 migration +5 archive +2 website checks pass,
including the public source CI. The actual current CLI (unchanged helper UUID)
passed all11 packaged behavior checks. Signed app install/update, legacy rename,
injected rename failure restoration and app-only rollback passed. Native startup
checks preserve/restores preferences, refuse duplicate receivers and isolate
explicit data roots. No real terminal API/model task was used by these checks.

The exact final Cueport receiver completed 600.037s /121samples:
mean/max RSS75.961/78.891MiB, CPU0.04500% of one core.
All sampled RSS remained strictly below80MiB with unchanged10s warmup/5s cadence.
Two preceding preparations failed at81.203 and80.422MiB and were never installed
or released. Transient setup objects are drained before idle; application menu
creation is deferred until the panel, Settings or Dock is shown. Retain failed
observations rather than transferring a measurement to different binaries.
This empty-receiver measurement excludes loaded UI, Codex/backend and other hosts.

The native synthetic Settings window showed Cueport, alpha.4/build4, controls and
Quit Cueport. After Command-Q the owned process exited; the immediate AX readback
timed out, so that UI-tool limitation is retained. Light/dark synthetic panels,
Settings and the new icon were inspected. These are not model/notification trials.
No further native model input was sent. Both daily application upgrades retain
their prior preferences/current data; stopped-profile migration keeps originals.
Full Dock, VoiceOver, Spaces and native-notification coverage remains incomplete.

## Historical alpha.3 automated and package evidence

- 198 Swift, 11 executable, 5 stopped-data migration, 3 recoverable app-archive
  and 2 website checks passed on the development host.
- A real bundled-helper setup failure was found before release: Foundation
  rejected the app identity as its own suite. The final helper uses its standard
  domain when bundled, and the explicit app suite only when standalone. Actual
  Air startup preference readback qualifies this correction separately.
- Actual signed installation/update, app-only rollback, injected swap failure
  restoration, active-receiver refusal and data preservation checks passed in
  private synthetic temporary locations.
- The selected ZIP passed extraction, arm64 architecture, strict signature,
  packaged-helper execution and preservation of foreign synthetic Hooks.
- Real Unix-socket integration verifies sequential admission, fresh peer identity
  and rejection of a changed origin before forwarding; distinct payloads are
  not replayed on a replacement connection.
- Both official native versions passed initialize and ephemeral thread
  start/unsubscribe using empty HOME/CODEX_HOME on both Macs, with zero model
  tasks and no real authentication/configuration files. This is protocol
  compatibility evidence, not native iTerm/notification acceptance.

## Resource scope

The exact daily candidate's empty receiver completed 600.029 seconds / 121
samples, with a 10-second warmup and 5-second sampling. Mean/max RSS was
75.595/78.719 MiB; CPU 0.03666% of one core. Every sampled RSS was strictly below
80 MiB. Existing daily clients were preserved. Native/backend/model resources,
loaded UI, other hosts and longer durations are excluded from this measurement.
Earlier memory failures are not deleted or reclassified.

Both 12-hour transport runs completed with zero model turns. Native versions
0.169 and 0.170 each recovered all 143 controlled disconnects, including one
backend restart per run. The separate alpha.3 receiver recorded 1,441 RSS
samples over 43,200 seconds, peaking at 79.969 MiB. Its popover was opened
during the observation. These measurements apply to the observed builds.
The transport harness uses synthetic terminal identity and owned empty native
backends, with controlled proxy loss/backend restart; it does not establish
real TUI identity, model continuity or notification return.

## Native results and known gaps

Six new fixed local READY tasks were sent with native 0.170.0 before the final
packaged-helper preference correction. The receiver program/resources and
transport core are unchanged; final-helper native trials were not repeated. Five system
notification clicks had matching fresh original-source/exact-focus audits. One
click safely failed bounded focus readback and remained unreviewed; its original
mismatch cause is unconfirmed. A later unchanged-adapter direct return probe
matched the original source. That probe is not a sixth notification success.
The 30-success target is incomplete; old alpha.2 samples are not reused.

Air's native0.169 launch failed before any model task: original terminal checks
passed, then the upstream proxy exited1 before the WebSocket handshake. A scoped
official status query found the normal backend socket absent. Installing a
complete official0.170 package separately and starting its official local backend
restored CLI/managed/server0.170 status. This repair is not a completed Air native
notification check, and global older CLI aliases were retained.

The actual TEST Settings verifies the selected0.170 file/version, app release
and build, native update-source guidance, switch labels and state. Its Dock
switch was restored off. Dock visible/reopen inspection could not be completed
because the computer-use tool timed out. Current-release VoiceOver, full
appearance/Spaces/layout and broad native lifecycle matrices are incomplete.
TEST alert style was restored to its original temporary setting. No privacy,
Focus or power policy was bypassed.

The private READY driver is excluded from public source and packages. The
product cannot send terminal input, answer questions or approve requests.
See [alpha.2 evidence](quality-alpha2.md) for historical, separately scoped checks.


## Configured-Hook dependency regression fixed before alpha.4 publication

An inactive development bundle was recoverably archived while the default Codex
Hooks still referenced its helper. Subsequent lifecycle hooks failed with shell
exit127. The exact original signed bundle was restored to its referenced path;
all seven configured own helpers resolve again. Hook command strings, trust and
foreign handlers were not rewritten. The independent Cueport daily app/data were
not rolled back. Keep this configured dependency until a separately reviewed
Hook migration; inactivity alone is not proof that a bundle is unused.

The cleanup planner and apply path now inspect default global Hook dependency
metadata and retain referenced bundles even without a live process. First-name-
change installation refuses referenced legacy applications and rechecks before
replacement. Unsafe/unreadable configuration stops the operation. Hook commands
are neither executed by this inspection nor logged. Added regression checks cover
unmapped references, newly introduced references, unsafe/symlinked metadata and
preservation of foreign fields. Actual signed rename/failure recovery tests also
cover Hook references appearing during staging. This does not inspect arbitrary
custom Hook sources: keep those dependencies until explicitly reviewed.
