# Swift Networking completion checks

- For a complete implementation, run the repository-safe validation profile: `make all` (lint, host build, full package tests).
- If the task targets Apple platform compatibility, additionally run `make platform-build PLATFORM=<platform>` for the relevant generic destination.
- Before any authorized commit, run `cubic review`, fix validated findings, and repeat until clean or only explicitly disputed findings remain.
- After any authorized push, inspect the GitHub review and resolve validated findings before claiming completion.
- Keep Git changes within the authorized paths and report focused versus full-suite/device qualification honestly.