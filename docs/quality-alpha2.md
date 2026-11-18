# Alpha.2 quality evidence

This experimental release supports explicit connected launch/resume with native
arm64 Codex 0.169.0 and iTerm2 3.7.7 on the tested Apple Silicon macOS host.
It uses ad-hoc signing. Ordinary unwrapped Codex attachment, Developer ID signing
and notarization remain outside this release; this is not complete P0 acceptance.

## Program and package

- 179 Release Swift tests and 11 tests against the packaged helper passed.
- Signed installation/update, app-only rollback and injected failure restoration
  passed with synthetic data. The native sample popover retained a 323 pt list.
- Final ZIP extraction, arm64 architecture, signature integrity, packaged helper
  execution and preservation of foreign synthetic Hooks passed.
- Menu-glyph 1x/2x alpha, nominal size, optical alignment and template intent were
  checked against the original system symbol. Third-party terms are included.
- A packaging input mismatch was found before publication. That unpublished
  preparation was excluded. The selected package preserves the tested program
  code, adds the final aligned resources and has a renewed ad-hoc signature.
  Actual Mach-O identities, code comparison, whole-bundle fingerprint and ZIP
  extraction establish the selected bytes; a copied build receipt does not.

## Resource measurement

The final daily-presentation empty receiver completed **600.030 seconds / 121
samples**, after the original 10-second warmup with 5-second sampling. Mean/max
RSS was **65.430/79.328 MiB**; CPU was **0.02333%** of one core. Every sampled RSS
value was strictly below 80 MiB, including the first sample. The original gates
passed for this artifact on this host. The one daily receiver and five existing
workers remained alive throughout; their uncontrolled workloads are separate.

Earlier memory failures remain recorded. The rejected package's 79.531 MiB run
is not reused. Loaded workloads, open UI, other Macs and the separate review
presentation are not qualified by this empty-receiver measurement.

## Real notification return

The candidate program recorded **30 successful native notification returns**:
21 before the final resource alignment and 9 using the aligned review package.
All 30 matched the fresh original terminal source and exact focused session.
Successful-only callback latency was **p50 628.770 ms / p95 743.058 ms / max
1341.921 ms**, passing the selected p95 <2 s target.

The native trial also retains one safe verification refusal (2869.202 ms), which
did not mark the session reviewed, and one quota interruption. The private QA
driver had switched foreground before waiting for the failed callback; that
interference was removed and later trials passed, but the original cause remains
unconfirmed. The failure is not erased or counted as success. Including two
initial transport investigations, the owner-authorized total was 34 fixed tasks.

A separate retained cohort of **34 real stopped events** was matched to its exact
persisted macOS-acceptance receipt keys: event-to-acceptance p50 **51.030 ms**,
p95 **58.226 ms**, max **60.316 ms**. This broader cohort includes unclicked and
failed trials; it is not the same denominator as the 30 successful returns.
These are real protocol events, not manual delivery tests. Acceptance timing is
distinct from visible presentation. The continuation used TEST Settings as the foreground
starting point; it does not repeat or extend the earlier registered Spaces/layout
matrix. Focus, display-sharing and other OS policies still govern visible alerts.

## Native interaction and accessibility

The actual connected panel was inspected in light/dark and increased-contrast
mode, with readable card/status/utility controls and no clipping in the inspected
views. With reduced motion enabled, panel opening, card focus and utility
navigation worked. Keyboard navigation reached Settings controls and the main
card/Diagnostics/Settings/More sequence; visible focus outlines were inspected.
Space activated the native file/version check and verified Codex 0.169.0.

The owner heard correct names and button roles for three Settings actions and
confirmed the actual main card's project name, ready/idle state and button role.
Long-name and multi-state sample renders remain sample evidence rather than a
complete live accessibility matrix. In the Settings window, lower controls may
need manual scrolling to make keyboard focus visible; automatic focus scrolling
is not qualified. All temporary system preferences were restored.

The READY-only private QA driver is excluded from source and package. The product
cannot send terminal input, answer requests or grant approvals. Reviewing a
notification never proves that a request has been resolved.
