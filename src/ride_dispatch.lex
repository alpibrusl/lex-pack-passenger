# ride_dispatch.lex — booking → live-fleet assignment orchestration (taxi finish).
#
# The seam that turns the on-demand pieces into a working flow: a rider booking
# (#169) is matched against the live fleet (#168 positions via #167 dispatch),
# the nearest vehicle is assigned, the booking advances booked -> en_route, and
# the assignment is stamped on the tamper-evident trail.
#
# This is NOT a new primitive — it's the same pattern the other packs already use
# (a pack calls a service and writes the outcome to the trail): delivery -> lex-
# routing, cold-chain -> lex-telemetry, construction -> the spend gate. Here the
# service is the dispatch matcher; everything else is reuse.
#
#   POST /passenger/bookings/:id/dispatch  { radius_km?, cruise_kmh? }
#        -> assign the nearest FREE live vehicle (skips ones already en_route to
#           another booking), advance the booking, return the ETA.
#   GET  /passenger/bookings/:id/assignment -> the current assignment for a booking.
#   GET  /passenger/bookings/:id/eta        -> recompute the live ETA from the
#           assigned vehicle's current position; on arrival, completes the ride.

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

import "./dispatch" as dispatch

import "./dispatch_http" as dispatch_http

import "./passenger" as passenger

type BookingLoc = { pickup_lat :: Float, pickup_lon :: Float, status :: Str }

type AssignmentRow = { booking_id :: Str, vehicle_ref :: Str, distance_km :: Float, eta_min :: Float, status :: Str, assigned_ms :: Int }

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
# rejects a PInt (i64) bind just like REAL rejected PFloat, so assigned_ms
# widens to BIGINT too. The ALTERs below widen an already-deployed table in
# place (no-op on SQLite; no-op on Postgres once already widened).
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS ride_assignments (booking_id TEXT NOT NULL PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'demo', vehicle_ref TEXT NOT NULL DEFAULT '', distance_km DOUBLE PRECISION NOT NULL DEFAULT 0, eta_min DOUBLE PRECISION NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT '', assigned_ms BIGINT NOT NULL DEFAULT 0)", [])
  let __dk := sql.exec(db, "ALTER TABLE ride_assignments ALTER COLUMN distance_km TYPE DOUBLE PRECISION", [])
  let __em := sql.exec(db, "ALTER TABLE ride_assignments ALTER COLUMN eta_min TYPE DOUBLE PRECISION", [])
  let __am := sql.exec(db, "ALTER TABLE ride_assignments ALTER COLUMN assigned_ms TYPE BIGINT", [])
  ()
}

fn load_booking(db :: Db, tenant :: Str, id :: Str) -> [sql] Option[BookingLoc] {
  let rows :: Result[List[BookingLoc], SqlError] := sql.query(db, "SELECT pickup_lat, pickup_lon, status FROM passenger_bookings WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn load_assignment(db :: Db, tenant :: Str, id :: Str) -> [sql] Option[AssignmentRow] {
  let rows :: Result[List[AssignmentRow], SqlError] := sql.query(db, "SELECT booking_id, vehicle_ref, distance_km, eta_min, status, assigned_ms FROM ride_assignments WHERE tenant = ? AND booking_id = ?", [PStr(tenant), PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

# Vehicles currently en_route to some OTHER booking — occupied, so a fresh
# dispatch shouldn't offer them.
fn busy_vehicles(db :: Db, tenant :: Str, exclude_booking :: Str) -> [sql] List[Str] {
  let rows :: Result[List[{ vehicle_ref :: Str }], SqlError] := sql.query(db, "SELECT vehicle_ref FROM ride_assignments WHERE tenant = ? AND status = 'en_route' AND booking_id <> ?", [PStr(tenant), PStr(exclude_booking)])
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: { vehicle_ref :: Str }) -> Str {
      r.vehicle_ref
    }),
  }
}

fn is_free(busy :: List[Str], ref :: Str) -> Bool {
  list.is_empty(list.filter(busy, fn (v :: Str) -> Bool {
    v == ref
  }))
}

fn find_vehicle(fleet :: List[dispatch.Cand], ref :: Str) -> Option[dispatch.Cand] {
  list.head(list.filter(fleet, fn (cnd :: dispatch.Cand) -> Bool {
    cnd.vehicle_ref == ref
  }))
}

# Assign the nearest available vehicle to a booking. Reuses dispatch's live-fleet
# fetch + matcher; advances the booking through the passenger state machine; and
# records both a ride_assignments row and a signed `ride.assigned` trail event.
fn handle_dispatch(c :: ctx.Ctx, db :: Db, telemetry_url :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing booking id\"}"),
    Some(booking_id) => {
      if str.is_empty(telemetry_url) {
        resp.json_status(503, "{\"error\":\"telemetry service not configured (TELEMETRY_URL unset)\"}")
      } else {
        let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
        match load_booking(db, tenant, booking_id) {
          None => resp.json_status(404, "{\"error\":\"booking not found\"}"),
          Some(bk) => {
            let radius := match jv.parse(c.body) {
              Ok(j) => jnum(j, "radius_km", 10.0),
              Err(_) => 10.0,
            }
            let cruise := match jv.parse(c.body) {
              Ok(j) => jnum(j, "cruise_kmh", 30.0),
              Err(_) => 30.0,
            }
            let fleet := dispatch_http.fetch_fleet(telemetry_url, tenant)
            let busy := busy_vehicles(db, tenant, booking_id)
            let free_fleet := list.filter(fleet, fn (cnd :: dispatch.Cand) -> Bool {
              is_free(busy, cnd.vehicle_ref)
            })
            match dispatch.best(bk.pickup_lat, bk.pickup_lon, free_fleet, radius, cruise) {
              None => resp.json_status(200, jv.stringify(JObj([("booking_id", JStr(booking_id)), ("assigned", JBool(false)), ("reason", JStr("no available vehicle within radius"))]))),
              Some(o) => {
                let now := time.now_ms()
                match sql.exec(db, "INSERT INTO ride_assignments (booking_id, tenant, vehicle_ref, distance_km, eta_min, status, assigned_ms) VALUES (?, ?, ?, ?, ?, 'en_route', ?) ON CONFLICT (booking_id) DO UPDATE SET vehicle_ref = excluded.vehicle_ref, distance_km = excluded.distance_km, eta_min = excluded.eta_min, status = 'en_route', assigned_ms = excluded.assigned_ms", [PStr(booking_id), PStr(tenant), PStr(o.vehicle_ref), PFloat(o.distance_km), PFloat(o.eta_min), PInt(now)]) {
                  Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                  Ok(_) => {
                    let status_result := if passenger.can_transition(bk.status, "en_route") {
                      match sql.exec(db, "UPDATE passenger_bookings SET status = 'en_route' WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(booking_id)]) {
                        Err(e) => Err(e.message),
                        Ok(_) => Ok("en_route"),
                      }
                    } else {
                      Ok(bk.status)
                    }
                    match status_result {
                      Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                      Ok(new_status) => {
                        let log := settlement.trail_on(db)
                        let __e := tlog.append(log, "ride.assigned", None, jv.stringify(JObj([("booking_id", JStr(booking_id)), ("vehicle_ref", JStr(o.vehicle_ref)), ("tenant", JStr(tenant)), ("distance_km", JFloat(o.distance_km)), ("eta_min", JFloat(o.eta_min)), ("booking_status", JStr(new_status)), ("at_ms", JInt(now))])))
                        resp.json_status(201, jv.stringify(JObj([("booking_id", JStr(booking_id)), ("assigned", JBool(true)), ("vehicle_ref", JStr(o.vehicle_ref)), ("distance_km", JFloat(dispatch.r2(o.distance_km))), ("eta_min", JFloat(dispatch.r2(o.eta_min))), ("booking_status", JStr(new_status))])))
                      },
                    }
                  },
                }
              },
            }
          },
        }
      }
    },
  }
}

fn assignment_json(a :: AssignmentRow) -> jv.Json {
  JObj([("booking_id", JStr(a.booking_id)), ("vehicle_ref", JStr(a.vehicle_ref)), ("distance_km", JFloat(a.distance_km)), ("eta_min", JFloat(a.eta_min)), ("status", JStr(a.status)), ("assigned_ms", JInt(a.assigned_ms))])
}

fn handle_get_assignment(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing booking id\"}"),
    Some(booking_id) => {
      let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
      match load_assignment(db, tenant, booking_id) {
        None => resp.json_status(404, "{\"error\":\"no assignment for booking\"}"),
        Some(a) => resp.json(jv.stringify(assignment_json(a))),
      }
    },
  }
}

# On arrival (assigned vehicle within ~150 m of the pickup) the ride completes.
fn arrival_km() -> Float {
  0.15
}

# Recompute the ETA from the assigned vehicle's CURRENT position, and complete
# the ride once it reaches the pickup. Persists the fresh distance/ETA so the
# assignment view stays live; a `ride.completed` event lands on the trail on
# arrival. This is the poll the map uses for a live ETA countdown.
fn handle_eta(c :: ctx.Ctx, db :: Db, telemetry_url :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing booking id\"}"),
    Some(booking_id) => {
      if str.is_empty(telemetry_url) {
        resp.json_status(503, "{\"error\":\"telemetry service not configured (TELEMETRY_URL unset)\"}")
      } else {
        let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
        match load_booking(db, tenant, booking_id) {
          None => resp.json_status(404, "{\"error\":\"booking not found\"}"),
          Some(bk) => match load_assignment(db, tenant, booking_id) {
            None => resp.json_status(404, "{\"error\":\"no assignment for booking\"}"),
            Some(a) => {
              let fleet := dispatch_http.fetch_fleet(telemetry_url, tenant)
              match find_vehicle(fleet, a.vehicle_ref) {
                None => resp.json(jv.stringify(JObj([("booking_id", JStr(booking_id)), ("vehicle_ref", JStr(a.vehicle_ref)), ("distance_km", JFloat(a.distance_km)), ("eta_min", JFloat(a.eta_min)), ("arrived", JBool(false)), ("status", JStr(a.status)), ("note", JStr("vehicle not in live feed; last-known ETA"))]))),
                Some(v) => {
                  let dist := dispatch.haversine_km(bk.pickup_lat, bk.pickup_lon, v.lat, v.lon)
                  let eta := dispatch.eta_minutes(dist, 30.0)
                  let arrived := dist <= arrival_km()
                  let status_result := if arrived {
                    match sql.exec(db, "UPDATE ride_assignments SET status = 'completed', distance_km = ?, eta_min = 0 WHERE tenant = ? AND booking_id = ?", [PFloat(dist), PStr(tenant), PStr(booking_id)]) {
                      Err(e) => Err(e.message),
                      Ok(_) => {
                        let booking_result := if passenger.can_transition(bk.status, "completed") {
                          match sql.exec(db, "UPDATE passenger_bookings SET status = 'completed' WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(booking_id)]) {
                            Err(e) => Err(e.message),
                            Ok(_) => Ok(()),
                          }
                        } else {
                          Ok(())
                        }
                        match booking_result {
                          Err(e) => Err(e),
                          Ok(_) => {
                            let log := settlement.trail_on(db)
                            let __e := tlog.append(log, "ride.completed", None, jv.stringify(JObj([("booking_id", JStr(booking_id)), ("vehicle_ref", JStr(a.vehicle_ref)), ("tenant", JStr(tenant)), ("at_ms", JInt(time.now_ms()))])))
                            Ok("completed")
                          },
                        }
                      },
                    }
                  } else {
                    match sql.exec(db, "UPDATE ride_assignments SET distance_km = ?, eta_min = ? WHERE tenant = ? AND booking_id = ?", [PFloat(dist), PFloat(eta), PStr(tenant), PStr(booking_id)]) {
                      Err(e) => Err(e.message),
                      Ok(_) => Ok(a.status),
                    }
                  }
                  match status_result {
                    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                    Ok(new_status) => resp.json(jv.stringify(JObj([("booking_id", JStr(booking_id)), ("vehicle_ref", JStr(a.vehicle_ref)), ("distance_km", JFloat(dispatch.r2(dist))), ("eta_min", JFloat(dispatch.r2(eta))), ("arrived", JBool(arrived)), ("status", JStr(new_status))]))),
                  }
                },
              }
            },
          },
        }
      }
    },
  }
}

fn mount(r :: router.Router, db :: Db, telemetry_url :: Str) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let r_disp := router.route_effectful(r, "POST", "/passenger/bookings/:id/dispatch", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_dispatch(c, db, telemetry_url)
  })
  let r_asg := router.route_effectful(r_disp, "GET", "/passenger/bookings/:id/assignment", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_get_assignment(c, db)
  })
  router.route_effectful(r_asg, "GET", "/passenger/bookings/:id/eta", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_eta(c, db, telemetry_url)
  })
}

