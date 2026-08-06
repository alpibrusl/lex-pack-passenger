# passenger_agent.lex — an LLM-driven agent persona that operates THIS
# pack's own REST service (the /passenger/* booking + dispatch routes across
# passenger_http.lex and ride_dispatch.lex).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex.
# Deliberately narrow vs. the pack's full route surface: excludes the older
# booking-less dispatch_http.lex match/request routes (superseded by
# ride_dispatch.lex's booking-aware dispatch -- exposing both would let the
# agent double-dispatch a ride through two disconnected code paths), and
# excludes passenger_dsr.lex (GDPR data-subject-rights export/erase, a
# human/DPO-triggered action, bearer-key gated) and aiact_http.lex (AI Act
# Art.14 human-oversight controls -- giving the automated agent write access
# to override/contest ITS OWN dispatch decisions would undermine the
# oversight guarantee those routes exist for). The pack's own mount()
# already wraps the external telemetry backend dispatch needs -- this
# agent's tools only ever call self_base_url.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn passenger_capability() -> cap.Capability {
  cap.inbound("handle", "Operate on-demand mobility: register riders, book rides, dispatch the nearest live vehicle, track status/ETA, and record payment.", { title: "PassengerOps", description: "Inbound message for the passenger ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes) ────────────────────────────────
fn make_passenger_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("register_rider", "Register a new rider by name (and optional phone number). Returns the rider_id to use for bookings.", { title: "RegisterRider", description: "Rider registration.", fields: [sch.required_str("name", []), sch.optional(sch.required_str("phone", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/passenger/riders"), jv.stringify(args), ""))
  }), t.define("book_ride", "Book a ride for a registered rider: pickup and dropoff coordinates plus the estimated distance and duration. Returns a fare quote under the tenant's fare policy.", { title: "BookRide", description: "Ride booking.", fields: [sch.required_str("rider_id", []), sch.required_float("pickup_lat", []), sch.required_float("pickup_lon", []), sch.required_float("dropoff_lat", []), sch.required_float("dropoff_lon", []), sch.required_float("distance_km", []), sch.required_float("duration_min", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/passenger/bookings"), jv.stringify(args), ""))
  }), t.define("dispatch_ride", "Assign the nearest available live vehicle to a booked ride.", { title: "DispatchRide", description: "Ride dispatch.", fields: [sch.required_str("booking_id", []), sch.optional(sch.required_float("radius_km", [])), sch.optional(sch.required_float("cruise_kmh", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/passenger/bookings/", jstr(args, "booking_id"), "/dispatch"], ""), jv.stringify(args), ""))
  }), t.define("update_ride_status", "Change a booking's status directly -- e.g. cancel it or mark a no-show.", { title: "UpdateRideStatus", description: "Ride status update.", fields: [sch.required_str("booking_id", []), sch.required_str("status", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/passenger/bookings/", jstr(args, "booking_id"), "/status"], ""), jv.stringify(args), ""))
  }), t.define("get_ride_status", "Check where a ride currently stands: its vehicle assignment and a live ETA. Completes the ride automatically once the vehicle arrives.", { title: "GetRideStatus", description: "Ride status/ETA lookup.", fields: [sch.required_str("booking_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let assignment := http_get_json(str.join([self_base_url, "/passenger/bookings/", jstr(args, "booking_id"), "/assignment"], ""), "")
    let eta := http_get_json(str.join([self_base_url, "/passenger/bookings/", jstr(args, "booking_id"), "/eta"], ""), "")
    Ok(JObj([("assignment", assignment), ("eta", eta)]))
  }), t.define("record_ride_payment", "Record payment for a completed ride.", { title: "RecordRidePayment", description: "Ride payment recording.", fields: [sch.required_str("booking_id", []), sch.required_str("payment_ref", []), sch.optional(sch.required_str("provider", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/passenger/bookings/", jstr(args, "booking_id"), "/pay"], ""), jv.stringify(args), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn passenger_system_prompt(id :: Str) -> Str {
  str.join(["You are passenger ops agent ", id, ". You operate on-demand mobility: registering riders, booking rides, dispatching vehicles, tracking status, and recording payment.", " Use register_rider before a first booking, book_ride to quote and create a ride, dispatch_ride to assign the nearest live vehicle, get_ride_status to check assignment/ETA before answering status questions, update_ride_status for a cancel or no-show, and record_ride_payment once the ride completes.", " Be precise about booking_id and rider_id, and always name the specific ride you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_passenger_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := passenger_capability()
  let cfg := { id: id, kind: "passenger-ops", system_prompt: passenger_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_passenger_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Passenger ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

