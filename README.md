# lex-pack-passenger

Passenger / on-demand domain pack — rider registry, fares, bookings, live-fleet dispatch matching, ride orchestration, GDPR data-subject rights, and AI Act transparency/oversight over automated assignment. Folds together what were five separate modules (passenger, DSR, dispatch, ride-dispatch, AI Act) since they are one on-demand-mobility flow.

> **Status: scaffold.** This pack is being extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) — see [https://github.com/alpibrusl/lex-ev-fleet/issues/238](https://github.com/alpibrusl/lex-ev-fleet/issues/238) for the extraction plan and what still needs to move here. No cross-pack dependency — can be extracted independently. Calls lex-telemetry over HTTP for live fleet positions.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (one vertical's routes + `pack.DomainPack`) -> [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.
