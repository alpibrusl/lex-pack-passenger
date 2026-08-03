# lex-pack-passenger

Passenger / on-demand domain pack — rider registry, fares, bookings, live-fleet dispatch matching, ride orchestration, GDPR data-subject rights, and AI Act transparency/oversight over automated assignment.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #238](https://github.com/alpibrusl/lex-ev-fleet/issues/238)). Folds together what were eight separate files — `passenger`, `passenger_http`, `passenger_dsr`, `dispatch`, `dispatch_http`, `ride_dispatch`, `aiact`, `aiact_http` — since they are one on-demand-mobility flow, not several. `passenger_http.manifest()` is the single manifest for the whole pack; the other modules mount routes but don't declare a second one. No cross-pack dependency. `lex-telemetry` is a runtime HTTP backend (configured via `telemetry_url`) for live fleet positions, not a `lex.toml` dependency.

## Routes

```
POST /passenger/riders                        { name, phone? }
GET  /passenger/riders
PUT  /passenger/fare-policy                   { base, per_km, per_min, min_fare, no_show_fee, currency }
GET  /passenger/fare-policy
POST /passenger/bookings                      { rider_id, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, distance_km, duration_min }
GET  /passenger/bookings
POST /passenger/bookings/:id/status           { status }         -> validated transition; sets final fare / no-show fee
POST /passenger/bookings/:id/pay              { payment_ref, provider? } -> records the PSP-reported settlement
POST /passenger/bookings/:id/dispatch         { radius_km?, cruise_kmh? } -> assign the nearest free live vehicle
GET  /passenger/bookings/:id/assignment       -> the current assignment for a booking
GET  /passenger/bookings/:id/eta              -> recompute the live ETA; completes the ride on arrival
POST /passenger/dsr/export                    { subject } -> Art. 15 export (signed archive)
POST /passenger/dsr/erase                     { subject } -> Art. 17 erasure (anonymise + redact PII)
POST /dispatch/match                          { pickup_lat, pickup_lon, radius_km?, cruise_kmh?, k? } -> preview shortlist
POST /dispatch/request                        { pickup_lat, pickup_lon, dropoff_lat?, dropoff_lon?, radius_km?, cruise_kmh? } -> firm assignment
GET  /dispatch/requests                       -> recent rides
GET  /aiact/dispatch/disclosure               -> the AI Act system card (public transparency)
POST /aiact/dispatch/:ride_ref/oversight      { action, reviewer, reason } -> human oversight over an automated assignment
GET  /aiact/dispatch/oversight                -> the oversight audit log
```

## Usage

```lex
import "lex-pack-passenger/passenger_http" as passenger_http
import "lex-pack-passenger/dispatch_http" as dispatch_http
import "lex-pack-passenger/passenger_dsr" as passenger_dsr
import "lex-pack-passenger/aiact_http" as aiact_http
import "lex-pack-passenger/ride_dispatch" as ride_dispatch

# in your router-wiring code (mount in this order — ride_dispatch calls
# dispatch_http.fetch_fleet, and passenger routes must exist first):
let r0 := passenger_http.mount(router.new(), db)
let r1 := dispatch_http.mount(r0, db, telemetry_url)
let r2 := passenger_dsr.mount(r1, db, dsr_key, sign_seed, pub_b64)
let r3 := aiact_http.mount(r2, db)
let r := ride_dispatch.mount(r3, db, telemetry_url)
```

`passenger_http.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.
