# File-backed download ownership

Status: Accepted for Networking 1.0.

## Context

Large responses should use URLSession download tasks without loading the full file into memory or
keeping duplicate raw response bytes. Temporary files also need explicit ownership across validation,
retry, authentication replay, cancellation, and caller handoff.

## Decision

Downloads remain file-backed through authentication recovery, retry, and validation. A
response-dependent destination is resolved only after validation succeeds; only the accepted file is
moved or adopted into the result. Networking cleans temporary files abandoned by replay, rejection,
cancellation, or failure. `DownloadedFile` automatically cleans an unexposed temporary file until its
`url` is read or `move(to:)` succeeds. Reading `url` transfers practical cleanup responsibility to
the caller. A successful move updates the object's current URL, disables automatic library cleanup,
and transfers practical cleanup responsibility for the destination to the caller. A failed move
leaves the current URL and automatic cleanup unchanged. A file written directly to a caller-selected
destination is never automatically removed.

## Consequences

- Download memory use does not scale with the retained response body.
- Failed or retried responses do not touch a caller's final destination.
- Cleanup responsibility is explicit at the boundary where a file URL becomes caller-visible.
- A successful move updates the object's current URL, disables automatic library cleanup, and leaves
  practical cleanup responsibility with the caller.
- Caller-selected files are not deleted during deinitialization.

See spec §§24–25, §§32–33, and §53.11.
