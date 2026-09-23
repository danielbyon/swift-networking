# Swift Networking local commands

- Run from repository root.
- `make all` runs lint, host build, and all tests.
- Individual checks: `make lint`, `make build`, `make test`.
- Generic Apple build: `make platform-build PLATFORM=iOS`, or replace with `macOS`, `tvOS`, `watchOS`, or `visionOS`.
- `make format` applies formatting and changes files; use only when explicitly authorized.
- `make hooks-install` changes local Git configuration; use only when explicitly authorized.
- Prefer the repository Make targets over arbitrary validation commands when the task specifies the safe workflow.