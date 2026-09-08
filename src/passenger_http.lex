# passenger_http.lex — passenger domain pack (lex-ev-fleet#169).
#
# The rider as a first-class actor: a rider registry, a per-tenant fare tariff,
# bookings with a quoted fare, a booking lifecycle (booked -> en_route ->
# completed, with cancel/no-show), and a B2C payment hand-off.
#
# Payment note: this records the OUTCOME the tenant's PSP reports (a payment_ref
# the PSP already captured) — the platform never sees or handles card data, and
# no funds move here. B2C rider payments are kept separate from the B2B
# settlement trail; both, though, get a tamper-evident event for audit.
#
#   POST /passenger/riders               { name, phone? }
#   GET  /passenger/riders
#   PUT  /passenger/fare-policy          { base, per_km, per_min, min_fare, no_show_fee, currency }
#   GET  /passenger/fare-policy
#   POST /passenger/bookings             { rider_id, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, distance_km, duration_min }
#   GET  /passenger/bookings
#   POST /passenger/bookings/:id/status  { status }         -> validated transition; sets final fare / no-show fee
#   POST /passenger/bookings/:id/pay     { payment_ref, provider? } -> records the PSP-reported settlement

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/positions" as pos

import "./passenger" as passenger

type RiderRow = { id :: Str, name :: Str, phone :: Str, created_ms :: Int }

type PolicyRow = { base :: Float, per_km :: Float, per_min :: Float, min_fare :: Float, no_show_fee :: Float, currency :: Str }

type BookingRow = { id :: Str, rider_id :: Str, status :: Str, distance_km :: Float, duration_min :: Float, fare_quote :: Float, fare_final :: Float, currency :: Str, payment_status :: Str, created_ms :: Int }

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jnum(j :: jv.Json, key :: Str, default :: Float) -> Float {
  match jv.get_field(j, key) {
    Some(JFloat(f)) => f,
    Some(JInt(n)) => int.to_float(n),
    _ => default,
  }
}

# DOUBLE PRECISION, not REAL: lex's Postgres driver binds PFloat params as
# Rust f64 (float8), which tokio-postgres refuses to serialize against a
# REAL (float4) column — see reference_lex_postgres memory. Same
# client-side-serialization gotcha applies on the Int side: INTEGER (int4)
# rejects a PInt (i64) bind just like REAL rejected PFloat, so created_ms
# widens to BIGINT too. The ALTERs below widen an already-deployed table in
# place (no-op on SQLite; no-op on Postgres once already widened).
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __r := sql.exec(db, "CREATE TABLE IF NOT EXISTS passenger_riders (id TEXT NOT NULL PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'demo', name TEXT NOT NULL DEFAULT '', phone TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL DEFAULT 0)", [])
  let __p := sql.exec(db, "CREATE TABLE IF NOT EXISTS passenger_fare_policies (tenant TEXT NOT NULL PRIMARY KEY, base DOUBLE PRECISION NOT NULL DEFAULT 0, per_km DOUBLE PRECISION NOT NULL DEFAULT 0, per_min DOUBLE PRECISION NOT NULL DEFAULT 0, min_fare DOUBLE PRECISION NOT NULL DEFAULT 0, no_show_fee DOUBLE PRECISION NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT 'EUR')", [])
  let __b := sql.exec(db, "CREATE TABLE IF NOT EXISTS passenger_bookings (id TEXT NOT NULL PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'demo', rider_id TEXT NOT NULL DEFAULT '', pickup_lat DOUBLE PRECISION NOT NULL DEFAULT 0, pickup_lon DOUBLE PRECISION NOT NULL DEFAULT 0, dropoff_lat DOUBLE PRECISION NOT NULL DEFAULT 0, dropoff_lon DOUBLE PRECISION NOT NULL DEFAULT 0, distance_km DOUBLE PRECISION NOT NULL DEFAULT 0, duration_min DOUBLE PRECISION NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'booked', fare_quote DOUBLE PRECISION NOT NULL DEFAULT 0, fare_final DOUBLE PRECISION NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT 'EUR', payment_ref TEXT NOT NULL DEFAULT '', payment_status TEXT NOT NULL DEFAULT 'unpaid', created_ms BIGINT NOT NULL DEFAULT 0)", [])
  let __fb := sql.exec(db, "ALTER TABLE passenger_fare_policies ALTER COLUMN base TYPE DOUBLE PRECISION", [])
  let __fk := sql.exec(db, "ALTER TABLE passenger_fare_policies ALTER COLUMN per_km TYPE DOUBLE PRECISION", [])
  let __fm := sql.exec(db, "ALTER TABLE passenger_fare_policies ALTER COLUMN per_min TYPE DOUBLE PRECISION", [])
  let __fn := sql.exec(db, "ALTER TABLE passenger_fare_policies ALTER COLUMN min_fare TYPE DOUBLE PRECISION", [])
  let __fs := sql.exec(db, "ALTER TABLE passenger_fare_policies ALTER COLUMN no_show_fee TYPE DOUBLE PRECISION", [])
  let __bpl := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN pickup_lat TYPE DOUBLE PRECISION", [])
  let __bpo := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN pickup_lon TYPE DOUBLE PRECISION", [])
  let __bdl := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN dropoff_lat TYPE DOUBLE PRECISION", [])
  let __bdo := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN dropoff_lon TYPE DOUBLE PRECISION", [])
  let __bdk := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN distance_km TYPE DOUBLE PRECISION", [])
  let __bdm := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN duration_min TYPE DOUBLE PRECISION", [])
  let __bfq := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN fare_quote TYPE DOUBLE PRECISION", [])
  let __bff := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN fare_final TYPE DOUBLE PRECISION", [])
  let __rc := sql.exec(db, "ALTER TABLE passenger_riders ALTER COLUMN created_ms TYPE BIGINT", [])
  let __bc := sql.exec(db, "ALTER TABLE passenger_bookings ALTER COLUMN created_ms TYPE BIGINT", [])
  ()
}

# The tenant's fare tariff, or the shared urban default if none is set.
fn get_policy(db :: Db, tenant :: Str) -> [sql] passenger.FarePolicy {
  let rows :: Result[List[PolicyRow], SqlError] := sql.query(db, "SELECT base, per_km, per_min, min_fare, no_show_fee, currency FROM passenger_fare_policies WHERE tenant = ?", [PStr(tenant)])
  match rows {
    Err(_) => passenger.default_policy(),
    Ok(rs) => match list.head(rs) {
      None => passenger.default_policy(),
      Some(r) => { base: r.base, per_km: r.per_km, per_min: r.per_min, min_fare: r.min_fare, no_show_fee: r.no_show_fee, currency: r.currency },
    },
  }
}

fn handle_create_rider(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  match jv.parse(c.body) {
    Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
    Ok(j) => {
      let name := jstr(j, "name")
      if str.is_empty(name) {
        resp.bad_request("{\"error\":\"name is required\"}")
      } else {
        let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
        let rid := str.concat("rider-", int.to_str(time.now_ms()))
        match sql.exec(db, "INSERT INTO passenger_riders (id, tenant, name, phone, created_ms) VALUES (?, ?, ?, ?, ?)", [PStr(rid), PStr(tenant), PStr(name), PStr(jstr(j, "phone")), PInt(time.now_ms())]) {
          Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
          Ok(_) => resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("rider_id", JStr(rid)), ("name", JStr(name))]))),
        }
      }
    },
  }
}

fn rider_to_json(r :: RiderRow) -> jv.Json {
  JObj([("rider_id", JStr(r.id)), ("name", JStr(r.name)), ("phone", JStr(r.phone)), ("created_ms", JInt(r.created_ms))])
}

fn handle_list_riders(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
  let rows :: Result[List[RiderRow], SqlError] := sql.query(db, "SELECT id, name, phone, created_ms FROM passenger_riders WHERE tenant = ? ORDER BY created_ms DESC LIMIT 200", [PStr(tenant)])
  match rows {
    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
    Ok(rs) => resp.json(jv.stringify(JList(list.map(rs, rider_to_json)))),
  }
}

fn handle_set_policy(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  match jv.parse(c.body) {
    Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
    Ok(j) => {
      let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
      let base := jnum(j, "base", 2.5)
      let per_km := jnum(j, "per_km", 1.1)
      let per_min := jnum(j, "per_min", 0.2)
      let min_fare := jnum(j, "min_fare", 4.0)
      let no_show := jnum(j, "no_show_fee", 5.0)
      let currency := match jv.get_field(j, "currency") {
        Some(JStr(s)) => s,
        _ => "EUR",
      }
      match sql.exec(db, "INSERT INTO passenger_fare_policies (tenant, base, per_km, per_min, min_fare, no_show_fee, currency) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (tenant) DO UPDATE SET base = ?, per_km = ?, per_min = ?, min_fare = ?, no_show_fee = ?, currency = ?", [PStr(tenant), PFloat(base), PFloat(per_km), PFloat(per_min), PFloat(min_fare), PFloat(no_show), PStr(currency), PFloat(base), PFloat(per_km), PFloat(per_min), PFloat(min_fare), PFloat(no_show), PStr(currency)]) {
        Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
        Ok(_) => resp.json(passenger.policy_json({ base: base, per_km: per_km, per_min: per_min, min_fare: min_fare, no_show_fee: no_show, currency: currency })),
      }
    },
  }
}

fn handle_get_policy(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
  resp.json(passenger.policy_json(get_policy(db, tenant)))
}

fn handle_create_booking(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  match jv.parse(c.body) {
    Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
    Ok(j) => {
      let rider_id := jstr(j, "rider_id")
      if str.is_empty(rider_id) {
        resp.bad_request("{\"error\":\"rider_id is required\"}")
      } else {
        let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
        let policy := get_policy(db, tenant)
        let dist := jnum(j, "distance_km", 0.0)
        let dur := jnum(j, "duration_min", 0.0)
        let quote := passenger.quote_fare(policy, dist, dur)
        let now := time.now_ms()
        let bid := str.concat("bk-", int.to_str(now))
        match sql.exec(db, "INSERT INTO passenger_bookings (id, tenant, rider_id, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, distance_km, duration_min, status, fare_quote, fare_final, currency, payment_ref, payment_status, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'booked', ?, 0, ?, '', 'unpaid', ?)", [PStr(bid), PStr(tenant), PStr(rider_id), PFloat(jnum(j, "pickup_lat", 0.0)), PFloat(jnum(j, "pickup_lon", 0.0)), PFloat(jnum(j, "dropoff_lat", 0.0)), PFloat(jnum(j, "dropoff_lon", 0.0)), PFloat(dist), PFloat(dur), PFloat(quote), PStr(policy.currency), PInt(now)]) {
          Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
          Ok(_) => {
            let log := settlement.trail_on(db)
            let __e := tlog.append(log, "passenger.booking", None, jv.stringify(JObj([("booking_id", JStr(bid)), ("rider_id", JStr(rider_id)), ("tenant", JStr(tenant)), ("fare_quote", JFloat(quote)), ("currency", JStr(policy.currency)), ("at_ms", JInt(now))])))
            resp.json_status(201, jv.stringify(JObj([("booking_id", JStr(bid)), ("status", JStr("booked")), ("fare_quote", JFloat(quote)), ("currency", JStr(policy.currency))])))
          },
        }
      }
    },
  }
}

fn booking_to_json(b :: BookingRow) -> jv.Json {
  JObj([("booking_id", JStr(b.id)), ("rider_id", JStr(b.rider_id)), ("status", JStr(b.status)), ("distance_km", JFloat(b.distance_km)), ("duration_min", JFloat(b.duration_min)), ("fare_quote", JFloat(b.fare_quote)), ("fare_final", JFloat(b.fare_final)), ("currency", JStr(b.currency)), ("payment_status", JStr(b.payment_status)), ("created_ms", JInt(b.created_ms))])
}

fn handle_list_bookings(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
  let rows :: Result[List[BookingRow], SqlError] := sql.query(db, "SELECT id, rider_id, status, distance_km, duration_min, fare_quote, fare_final, currency, payment_status, created_ms FROM passenger_bookings WHERE tenant = ? ORDER BY created_ms DESC LIMIT 200", [PStr(tenant)])
  match rows {
    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
    Ok(rs) => resp.json(jv.stringify(JList(list.map(rs, booking_to_json)))),
  }
}

fn load_booking(db :: Db, tenant :: Str, id :: Str) -> [sql] Option[BookingRow] {
  let rows :: Result[List[BookingRow], SqlError] := sql.query(db, "SELECT id, rider_id, status, distance_km, duration_min, fare_quote, fare_final, currency, payment_status, created_ms FROM passenger_bookings WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn handle_booking_status(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing booking id\"}"),
    Some(id) => match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let to := jstr(j, "status")
        if not passenger.valid_status(to) {
          resp.bad_request("{\"error\":\"unknown status\"}")
        } else {
          let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
          match load_booking(db, tenant, id) {
            None => resp.json_status(404, "{\"error\":\"booking not found\"}"),
            Some(b) => if not passenger.can_transition(b.status, to) {
              resp.json_status(409, str.concat("{\"error\":\"illegal transition from ", str.concat(b.status, str.concat(" to ", str.concat(to, "\"}")))))
            } else {
              let policy := get_policy(db, tenant)
              let final := passenger.final_amount(policy, to, b.distance_km, b.duration_min)
              match sql.exec(db, "UPDATE passenger_bookings SET status = ?, fare_final = ? WHERE tenant = ? AND id = ?", [PStr(to), PFloat(final), PStr(tenant), PStr(id)]) {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                Ok(_) => {
                  let log := settlement.trail_on(db)
                  let __e := tlog.append(log, "passenger.status", None, jv.stringify(JObj([("booking_id", JStr(id)), ("tenant", JStr(tenant)), ("status", JStr(to)), ("fare_final", JFloat(final)), ("at_ms", JInt(time.now_ms()))])))
                  resp.json(jv.stringify(JObj([("booking_id", JStr(id)), ("status", JStr(to)), ("fare_final", JFloat(final)), ("currency", JStr(b.currency))])))
                },
              }
            },
          }
        }
      },
    },
  }
}

# Record a B2C payment the tenant's PSP has already captured. We store only the
# PSP's opaque reference and mark the booking paid — no card data, no fund
# movement here.
fn handle_booking_pay(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing booking id\"}"),
    Some(id) => match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let payment_ref := jstr(j, "payment_ref")
        if str.is_empty(payment_ref) {
          resp.bad_request("{\"error\":\"payment_ref (PSP reference) is required\"}")
        } else {
          let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
          match load_booking(db, tenant, id) {
            None => resp.json_status(404, "{\"error\":\"booking not found\"}"),
            Some(b) => match sql.exec(db, "UPDATE passenger_bookings SET payment_ref = ?, payment_status = 'paid' WHERE tenant = ? AND id = ?", [PStr(payment_ref), PStr(tenant), PStr(id)]) {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
              Ok(_) => {
                let log := settlement.trail_on(db)
                let __e := tlog.append(log, "passenger.payment", None, jv.stringify(JObj([("booking_id", JStr(id)), ("tenant", JStr(tenant)), ("payment_ref", JStr(payment_ref)), ("provider", JStr(jstr(j, "provider"))), ("amount", JFloat(b.fare_final)), ("currency", JStr(b.currency)), ("at_ms", JInt(time.now_ms()))])))
                resp.json(jv.stringify(JObj([("booking_id", JStr(id)), ("payment_status", JStr("paid")), ("payment_ref", JStr(payment_ref)), ("amount", JFloat(b.fare_final)), ("currency", JStr(b.currency))])))
              },
            },
          }
        }
      },
    },
  }
}

fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let r1 := router.route_effectful(r, "POST", "/passenger/riders", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_create_rider(c, db)
  })
  let r2 := router.route_effectful(r1, "GET", "/passenger/riders", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_list_riders(c, db)
  })
  let r3 := router.route_effectful(r2, "PUT", "/passenger/fare-policy", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_set_policy(c, db)
  })
  let r4 := router.route_effectful(r3, "GET", "/passenger/fare-policy", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_get_policy(c, db)
  })
  let r5 := router.route_effectful(r4, "POST", "/passenger/bookings", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_create_booking(c, db)
  })
  let r6 := router.route_effectful(r5, "GET", "/passenger/bookings", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_list_bookings(c, db)
  })
  let r7 := router.route_effectful(r6, "POST", "/passenger/bookings/:id/status", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_booking_status(c, db)
  })
  router.route_effectful(r7, "POST", "/passenger/bookings/:id/pay", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    handle_booking_pay(c, db)
  })
}

# The domain vocabulary this pack speaks (lex-soft/src/positions). Covers the
# whole on-demand-mobility flow this file anchors — dispatch_http/ride_dispatch
# assign the driver, passenger_dsr covers rider PII, aiact_http covers
# automated-assignment oversight — since they're one domain (#169/#171/#172),
# not four.
fn manifest() -> pos.PackManifest {
  { id: "passenger", title: "Passenger / on-demand", tagline: "Rider bookings matched to the live fleet, settled via the tenant's PSP.", pattern: "milestone_release", subject: "booking", subject_ref_field: "booking_id", custody_ref_field: "", parties: [{ position: "originator", name: "rider", title: "Rider — books a trip and is quoted a fare", field: "rider_id", required: true }, { position: "executor", name: "driver", title: "Driver — the nearest live vehicle assigned to the booking", field: "", required: false }, { position: "settler", name: "psp", title: "PSP — the tenant's payment provider whose outcome is recorded", field: "payment_ref", required: false }, { position: "observer", name: "auditor", title: "Auditor — reads booking/status/payment trail events", field: "", required: false }], relationships: [{ from: "rider", to: "driver", role: "dispatch", label: "the rider's booking is matched to the nearest available vehicle" }, { from: "rider", to: "psp", role: "settlement", label: "the rider pays via the tenant's PSP hand-off" }, { from: "driver", to: "auditor", role: "reporting", label: "booking/status/payment trail events are written for whoever audits the flow" }], event_kinds: ["passenger.booking", "passenger.status", "passenger.payment"], evidence_kinds: ["booking_status"], settles: true, route_prefix: "/passenger" }
}

