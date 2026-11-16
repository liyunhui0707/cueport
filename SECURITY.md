# Security and privacy

The application must never answer questions, approve permissions, send terminal
input or execute event-provided text. Routing requires a fresh unique exact
original iTerm session and process lifetime. Missing/conflicting/closed targets
fail visibly without title, project-directory or active-pane fallback.

Persistent data is metadata only: project basename, identifiers, timestamps,
states and process/terminal identity. Full connected protocol bytes pass transiently
through local memory. Prompts, code, tool commands/results, question content and
transcript paths are not persisted. Notification titles can hide project names.
No telemetry, cloud upload or external listening TCP service is provided.

Private local folders reject unsafe paths, ownership and permissions. Same-user
processes remain within the trust boundary; this does not protect against malware
already running as your account. The iTerm API has broader capabilities than the
subset used by this app; review normal native authorization carefully. Neither
Hook trust nor other notifiers are silently changed.

## Reporting

Use this repository's private vulnerability reporting / Security Advisories form.
Do not publish credentials, transcripts, raw protocol payloads or personal session
metadata in an Issue. Ordinary bugs can use a sanitized public Issue. Private
reporting is enabled for this repository.

The first channel is experimental. See [compatibility and acceptance](docs/compatibility.md)
for tested versions and unresolved limitations; there is no production-support SLA.
