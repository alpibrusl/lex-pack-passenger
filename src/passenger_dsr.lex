# passenger_dsr.lex — GDPR data-subject rights over rider PII (lex-ev-fleet#171).
#
# The passenger domain (#169) made the rider a first-class actor, which makes the
# rider a data subject with real-time location, payment and trip-history PII —
# higher volume and sensitivity than the B2B side, and special-category data once
# paratransit/medical transport is in scope. This extends the GDPR-04 DSR surface
# (lex-soft/src/dsr) to that data, keyed by `rider_id` and scoped to the tenant.
#
#   POST /passenger/dsr/export  { subject }  -> Art. 15: the rider's record + all
#                                               their bookings, as a signed archive.
#   POST /passenger/dsr/erase   { subject }  -> Art. 17: anonymise the rider (name,
#                                               phone) and redact location + payment
#                                               PII from their bookings, KEEPING the
#                                               fare/status rows for the financial-
#                                               retention obligation. Appends a
#                                               signed `passenger.dsr.erased` receipt
#                                               to the trail (counts only, no PII).
#
# The bearer/fail-closed gate and the ed25519 signed-envelope are reused verbatim
# from lex-soft/src/dsr — one implementation of that security-critical logic.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/dsr" as basedsr

type RiderRec = { id :: Str, name :: Str, phone :: Str, created_ms :: Int }

type BookingRec = { id :: Str, status :: Str, pickup_lat :: Float, pickup_lon :: Float, dropoff_lat :: Float, dropoff_lon :: Float, distance_km :: Float, duration_min :: Float, fare_quote :: Float, fare_final :: Float, currency :: Str, payment_ref :: Str, payment_status :: Str, created_ms :: Int }

type EraseCounts = { riders :: Int, bookings :: Int }

fn rider_rows(db :: Db, tenant :: Str, rider_id :: Str) -> [sql] List[RiderRec] {
  let rows :: Result[List[RiderRec], SqlError] := sql.query(db, "SELECT id, name, phone, created_ms FROM passenger_riders WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(rider_id)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn booking_rows(db :: Db, tenant :: Str, rider_id :: Str) -> [sql] List[BookingRec] {
  let rows :: Result[List[BookingRec], SqlError] := sql.query(db, "SELECT id, status, pickup_lat, pickup_lon, dropoff_lat, dropoff_lon, distance_km, duration_min, fare_quote, fare_final, currency, payment_ref, payment_status, created_ms FROM passenger_bookings WHERE tenant = ? AND rider_id = ? ORDER BY created_ms", [PStr(tenant), PStr(rider_id)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn rider_json(r :: RiderRec) -> jv.Json {
  JObj([("rider_id", JStr(r.id)), ("name", JStr(r.name)), ("phone", JStr(r.phone)), ("created_ms", JInt(r.created_ms))])
}

fn booking_json(b :: BookingRec) -> jv.Json {
  JObj([("booking_id", JStr(b.id)), ("status", JStr(b.status)), ("pickup_lat", JFloat(b.pickup_lat)), ("pickup_lon", JFloat(b.pickup_lon)), ("dropoff_lat", JFloat(b.dropoff_lat)), ("dropoff_lon", JFloat(b.dropoff_lon)), ("distance_km", JFloat(b.distance_km)), ("duration_min", JFloat(b.duration_min)), ("fare_quote", JFloat(b.fare_quote)), ("fare_final", JFloat(b.fare_final)), ("currency", JStr(b.currency)), ("payment_ref", JStr(b.payment_ref)), ("payment_status", JStr(b.payment_status)), ("created_ms", JInt(b.created_ms))])
}

# Art. 15 access payload: everything the passenger stores hold under this rider.
fn export_rider(db :: Db, tenant :: Str, rider_id :: Str) -> [sql, time] jv.Json {
  let riders := rider_rows(db, tenant, rider_id)
  let bookings := booking_rows(db, tenant, rider_id)
  JObj([("subject", JStr(rider_id)), ("tenant", JStr(tenant)), ("exported_at_ms", JInt(time.now_ms())), ("rider_count", JInt(list.len(riders))), ("booking_count", JInt(list.len(bookings))), ("rider", JList(list.map(riders, rider_json))), ("bookings", JList(list.map(bookings, booking_json)))])
}

# Art. 17 erasure. Rider identity is anonymised (name/phone cleared); each booking
# keeps its fare/status/dates (a financial record with its own retention duty) but
# loses the location and payment PII. Counts are read first so the receipt is
# accurate. A signed `passenger.dsr.erased` event records the erasure itself.
# Erasure must not sign/announce success unless the redacting writes actually
# landed — a silently-discarded UPDATE here would let a signed "erased" receipt
# go out (and the trail record it) for PII that was never redacted.
fn erase_rider(db :: Db, tenant :: Str, rider_id :: Str) -> [sql, fs_read, fs_write, time] Result[EraseCounts, Str] {
  let n_riders := list.len(rider_rows(db, tenant, rider_id))
  let n_bookings := list.len(booking_rows(db, tenant, rider_id))
  match sql.exec(db, "UPDATE passenger_riders SET name = '', phone = '' WHERE tenant = ? AND id = ?", [PStr(tenant), PStr(rider_id)]) {
    Err(e) => Err(e.message),
    Ok(_) => match sql.exec(db, "UPDATE passenger_bookings SET pickup_lat = 0, pickup_lon = 0, dropoff_lat = 0, dropoff_lon = 0, payment_ref = '' WHERE tenant = ? AND rider_id = ?", [PStr(tenant), PStr(rider_id)]) {
      Err(e) => Err(e.message),
      Ok(_) => {
        let log := settlement.trail_on(db)
        let payload := jv.stringify(JObj([("subject", JStr(rider_id)), ("tenant", JStr(tenant)), ("riders_anonymised", JInt(n_riders)), ("bookings_redacted", JInt(n_bookings)), ("erased_at_ms", JInt(time.now_ms()))]))
        let __t := tlog.append(log, "passenger.dsr.erased", None, payload)
        Ok({ riders: n_riders, bookings: n_bookings })
      },
    },
  }
}

fn export_response(db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  if not basedsr.authed(dsr_key, c) {
    if str.is_empty(dsr_key) {
      resp.forbidden("{\"error\":\"dsr endpoint disabled (DSR_KEY unset)\"}")
    } else {
      resp.unauthorized("{\"error\":\"missing or invalid bearer token\"}")
    }
  } else {
    let subject := basedsr.subject_of(c)
    if str.is_empty(subject) {
      resp.bad_request("{\"error\":\"subject (rider_id) is required\"}")
    } else {
      let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
      basedsr.signed_envelope(jv.stringify(export_rider(db, tenant, subject)), sign_seed, pub_b64)
    }
  }
}

fn erase_response(db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  if not basedsr.authed(dsr_key, c) {
    if str.is_empty(dsr_key) {
      resp.forbidden("{\"error\":\"dsr endpoint disabled (DSR_KEY unset)\"}")
    } else {
      resp.unauthorized("{\"error\":\"missing or invalid bearer token\"}")
    }
  } else {
    let subject := basedsr.subject_of(c)
    if str.is_empty(subject) {
      resp.bad_request("{\"error\":\"subject (rider_id) is required\"}")
    } else {
      let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
      match erase_rider(db, tenant, subject) {
        Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
        Ok(counts) => {
          let body := jv.stringify(JObj([("subject", JStr(subject)), ("tenant", JStr(tenant)), ("riders_anonymised", JInt(counts.riders)), ("bookings_redacted", JInt(counts.bookings)), ("erased_at_ms", JInt(time.now_ms())), ("note", JStr("rider identity anonymised; booking location + payment PII redacted; fare/status rows retained for the financial-retention obligation"))]))
          basedsr.signed_envelope(body, sign_seed, pub_b64)
        },
      }
    }
  }
}

# Host opt-in. Same DSR_KEY + ed25519 identity as the platform DSR (lex-soft), so
# the DPO operates one key and exports/receipts verify against one public key.
fn mount(r :: router.Router, db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str) -> router.Router {
  let r_ex := router.route_effectful(r, "POST", "/passenger/dsr/export", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    export_response(db, dsr_key, sign_seed, pub_b64, c)
  })
  router.route_effectful(r_ex, "POST", "/passenger/dsr/erase", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    erase_response(db, dsr_key, sign_seed, pub_b64, c)
  })
}

