# dispatch_http.lex — real-time on-demand matching pack (lex-ev-fleet#167).
#
# The matching math lives in dispatch.lex; this fetches the live fleet snapshot
# from the tenant's telemetry SoR (lex-telemetry#168 GET /positions/latest),
# ranks it against a pickup, and — for a firm request — assigns the nearest
# vehicle, persists the ride, and stamps a tamper-evident `dispatch.assign`
# event on the settlement trail.
#
#   POST /dispatch/match    { pickup_lat, pickup_lon, radius_km?, cruise_kmh?, k? }
#     -> preview: ranked shortlist of live vehicles (no assignment, no write).
#   POST /dispatch/request  { pickup_lat, pickup_lon, dropoff_lat?, dropoff_lon?,
#                             radius_km?, cruise_kmh? }
#     -> assign the nearest vehicle, record the ride + a `dispatch.assign` event.
#   GET  /dispatch/requests -> recent rides for the tenant.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.http" as http

import "std.bytes" as bytes

import "std.map" as map

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "./dispatch" as dispatch

type RideRow = { id :: Str, vehicle_ref :: Str, distance_km :: Float, eta_min :: Float, status :: Str, created_ms :: Int }

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

fn jint(j :: jv.Json, key :: Str, default :: Int) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => default,
  }
}

fn to_cand(j :: jv.Json) -> dispatch.Cand {
  { vehicle_ref: jstr(j, "vehicle_ref"), lat: jnum(j, "lat", 999.0), lon: jnum(j, "lon", 999.0), speed_kmh: jnum(j, "speed_kmh", 0.0) }
}

# A telemetry /positions/latest body is a JSON array of latest fixes; keep only
# rows with a ref and an in-range coordinate.
fn parse_candidates(body_s :: Str) -> List[dispatch.Cand] {
  match jv.parse(body_s) {
    Ok(JList(items)) => list.filter(list.map(items, to_cand), fn (c :: dispatch.Cand) -> Bool {
      not str.is_empty(c.vehicle_ref) and c.lat <= 90.0 and c.lat >= -90.0 and c.lon <= 180.0 and c.lon >= -180.0
    }),
    _ => [],
  }
}

fn fetch_fleet(telemetry_url :: Str, tenant :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] List[dispatch.Cand] {
  let base := { method: "GET", url: str.concat(telemetry_url, "/positions/latest"), headers: map.new(), body: None, timeout_ms: Some(20000) }
  let req := http.with_header(base, "X-Tenant-Id", tenant)
  match http.send(req) {
    Err(_) => [],
    Ok(res) => match bytes.to_str(res.body) {
      Ok(v) => parse_candidates(v),
      Err(_) => [],
    },
  }
}

fn valid_pickup(plat :: Float, plon :: Float) -> Bool {
  plat <= 90.0 and plat >= -90.0 and plon <= 180.0 and plon >= -180.0
}

fn ride_insert_stmt() -> Str {
  "INSERT INTO dispatch_rides (id, tenant, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, vehicle_ref, distance_km, eta_min, status, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
}

# DOUBLE PRECISION, not REAL: lex's Postgres driver binds PFloat params as
# Rust f64 (float8), which tokio-postgres refuses to serialize against a
# REAL (float4) column — see reference_lex_postgres memory. Same
# client-side-serialization gotcha applies on the Int side: INTEGER (int4)
# rejects a PInt (i64) bind just like REAL rejected PFloat, so created_ms
# widens to BIGINT too. The ALTERs below widen an already-deployed table in
# place (no-op on SQLite; no-op on Postgres once already widened).
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS dispatch_rides (id TEXT NOT NULL PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'demo', pickup_lat DOUBLE PRECISION NOT NULL DEFAULT 0, pickup_lon DOUBLE PRECISION NOT NULL DEFAULT 0, dropoff_lat DOUBLE PRECISION NOT NULL DEFAULT 0, dropoff_lon DOUBLE PRECISION NOT NULL DEFAULT 0, vehicle_ref TEXT NOT NULL DEFAULT '', distance_km DOUBLE PRECISION NOT NULL DEFAULT 0, eta_min DOUBLE PRECISION NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL DEFAULT 0)", [])
  let __pl := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN pickup_lat TYPE DOUBLE PRECISION", [])
  let __po := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN pickup_lon TYPE DOUBLE PRECISION", [])
  let __dl := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN dropoff_lat TYPE DOUBLE PRECISION", [])
  let __do := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN dropoff_lon TYPE DOUBLE PRECISION", [])
  let __dk := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN distance_km TYPE DOUBLE PRECISION", [])
  let __em := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN eta_min TYPE DOUBLE PRECISION", [])
  let __cm := sql.exec(db, "ALTER TABLE dispatch_rides ALTER COLUMN created_ms TYPE BIGINT", [])
  ()
}

# Preview: rank the live fleet for a pickup without assigning or writing anything.
fn handle_match(c :: ctx.Ctx, telemetry_url :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  if str.is_empty(telemetry_url) {
    resp.json_status(503, "{\"error\":\"telemetry service not configured (TELEMETRY_URL unset)\"}")
  } else {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let plat := jnum(j, "pickup_lat", 999.0)
        let plon := jnum(j, "pickup_lon", 999.0)
        if not valid_pickup(plat, plon) {
          resp.bad_request("{\"error\":\"pickup_lat and pickup_lon are required and must be in range\"}")
        } else {
          let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
          let cands := fetch_fleet(telemetry_url, tenant)
          resp.json(dispatch.offers_json(dispatch.rank(plat, plon, cands, jnum(j, "radius_km", 10.0), jnum(j, "cruise_kmh", 30.0), jint(j, "k", 5))))
        }
      },
    }
  }
}

# Firm request: assign the nearest vehicle, persist the ride, and record the
# assignment on the trail. An empty/out-of-range fleet yields an unmatched ride.
fn handle_request(c :: ctx.Ctx, db :: Db, telemetry_url :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  if str.is_empty(telemetry_url) {
    resp.json_status(503, "{\"error\":\"telemetry service not configured (TELEMETRY_URL unset)\"}")
  } else {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let plat := jnum(j, "pickup_lat", 999.0)
        let plon := jnum(j, "pickup_lon", 999.0)
        if not valid_pickup(plat, plon) {
          resp.bad_request("{\"error\":\"pickup_lat and pickup_lon are required and must be in range\"}")
        } else {
          let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
          let dlat := jnum(j, "dropoff_lat", 0.0)
          let dlon := jnum(j, "dropoff_lon", 0.0)
          let now := time.now_ms()
          let ride_id := str.concat("ride-", int.to_str(now))
          let cands := fetch_fleet(telemetry_url, tenant)
          match dispatch.best(plat, plon, cands, jnum(j, "radius_km", 10.0), jnum(j, "cruise_kmh", 30.0)) {
            None => {
              let __u := sql.exec(db, ride_insert_stmt(), [PStr(ride_id), PStr(tenant), PFloat(plat), PFloat(plon), PFloat(dlat), PFloat(dlon), PStr(""), PFloat(0.0), PFloat(0.0), PStr("unmatched"), PInt(now)])
              resp.json_status(200, jv.stringify(JObj([("ride_id", JStr(ride_id)), ("assigned", JBool(false)), ("reason", JStr("no available vehicle within radius"))])))
            },
            Some(o) => {
              let __a := sql.exec(db, ride_insert_stmt(), [PStr(ride_id), PStr(tenant), PFloat(plat), PFloat(plon), PFloat(dlat), PFloat(dlon), PStr(o.vehicle_ref), PFloat(o.distance_km), PFloat(o.eta_min), PStr("assigned"), PInt(now)])
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("ride_id", JStr(ride_id)), ("vehicle_ref", JStr(o.vehicle_ref)), ("tenant", JStr(tenant)), ("distance_km", JFloat(o.distance_km)), ("eta_min", JFloat(o.eta_min)), ("at_ms", JInt(now))]))
              let __e := tlog.append(log, "dispatch.assign", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ride_id", JStr(ride_id)), ("assigned", JBool(true)), ("vehicle_ref", JStr(o.vehicle_ref)), ("distance_km", JFloat(dispatch.r2(o.distance_km))), ("eta_min", JFloat(dispatch.r2(o.eta_min)))])))
            },
          }
        }
      },
    }
  }
}

fn ride_to_json(r :: RideRow) -> jv.Json {
  JObj([("ride_id", JStr(r.id)), ("vehicle_ref", JStr(r.vehicle_ref)), ("distance_km", JFloat(r.distance_km)), ("eta_min", JFloat(r.eta_min)), ("status", JStr(r.status)), ("created_ms", JInt(r.created_ms))])
}

fn handle_list(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
  let rows :: Result[List[RideRow], SqlError] := sql.query(db, "SELECT id, vehicle_ref, distance_km, eta_min, status, created_ms FROM dispatch_rides WHERE tenant = ? ORDER BY created_ms DESC LIMIT 100", [PStr(tenant)])
  match rows {
    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
    Ok(rs) => resp.json(jv.stringify(JList(list.map(rs, ride_to_json)))),
  }
}

fn mount(r :: router.Router, db :: Db, telemetry_url :: Str) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_match := router.route_effectful(r, "POST", "/dispatch/match", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_match(c, telemetry_url)
  })
  let with_req := router.route_effectful(with_match, "POST", "/dispatch/request", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_request(c, db, telemetry_url)
  })
  router.route_effectful(with_req, "GET", "/dispatch/requests", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list(c, db)
  })
}

