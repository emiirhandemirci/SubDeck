# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue.

## Security model

- **Desk is read-only.** It reads session data other tools already wrote and never modifies it.
- **Desk binds to `127.0.0.1` only** and rejects requests with a foreign `Host` header (protection against DNS rebinding).
- **Desk reads local transcripts, which may contain secrets** (tokens, keys, private code). Treat the dashboard and its output accordingly. `--no-content` disables the agent content endpoint.
- **The guard is a guard rail, not a sandbox.** It reduces accidental damage by agents; it does not stop a determined or malicious process. Do not rely on it as a security boundary.

When you report an issue, please redact secrets and transcript content from any samples.
