# Contributing

Preserve independent execution/request states, exact original terminal identity,
private metadata storage and the approved grouped panel. Never add automatic
approval, terminal input injection, content scraping or a title/directory fallback.

Build with `zsh scripts/build.sh release`; test with `zsh scripts/test.sh`.
There are no third-party Swift packages. Explain the trigger, resulting behavior,
relevant regressions and actual validation scope. Synthetic tests and sample
renders do not establish real Codex or Spaces acceptance.

UI changes need light/dark native review plus applicable keyboard/accessibility
checks. Keep demo data synthetic and incapable of routing or notifying.

Do not commit credentials, private logs, generated schemas, profiles or personal
screenshots. See [SECURITY.md](SECURITY.md) for private reporting.
Release versions are owner selected; do not bump them automatically.
