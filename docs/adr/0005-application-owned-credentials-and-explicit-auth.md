# Application-owned credentials and explicit authentication

Status: Accepted for Networking 1.0.

## Context

Credential representation, persistence, refresh, and coordination vary by application. A client may
serve both authenticated and unauthenticated endpoints, so client configuration alone must not
silently change an endpoint's contract.

## Decision

Applications own credentials and provide an `AuthenticationProvider` for adaptation and recovery.
Authentication is declared by each endpoint and defaults to none. A configured provider remains
dormant for endpoints that do not require authentication. Authentication adaptation is the final
outgoing request mutation stage; replay behavior follows the endpoint's separate authentication
replay limit.

## Consequences

- Networking does not define a library-owned credential or storage model.
- An endpoint states explicitly whether credentials are part of its request contract.
- Applications retain control of refresh and simultaneous-refresh coordination.
- Authentication replay can be reasoned about independently from ordinary retries; see ADR 0006.

See spec §19 and §§53.6, 53.17.
