# tests/test_passenger_agent.lex — pure-logic coverage for
# src/passenger_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/passenger_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_passenger_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_six_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_passenger_tools("http://127.0.0.1:8100")) == 6, "the persona exposes 6 curated tools across the booking/dispatch surface, deliberately excluding DSR and AI-Act oversight routes")
}

fn test_book_ride_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("rider_id", JStr("R-100")), ("pickup_lat", JFloat(52.37)), ("pickup_lon", JFloat(4.9)), ("dropoff_lat", JFloat(52.4)), ("dropoff_lon", JFloat(4.89)), ("distance_km", JFloat(5.0)), ("duration_min", JFloat(15.0))])
  match schema_of("book_ride") {
    None => Err("book_ride tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("book_ride's schema must accept passenger_http.lex's documented POST /passenger/bookings body"),
      Ok(_) => pass(),
    },
  }
}

fn test_dispatch_ride_schema_accepts_without_optional_params() -> Result[Unit, Str] {
  let sample := JObj([("booking_id", JStr("B-100"))])
  match schema_of("dispatch_ride") {
    None => Err("dispatch_ride tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("dispatch_ride's radius_km/cruise_kmh must be optional -- the route defaults them"),
      Ok(_) => pass(),
    },
  }
}

fn test_update_ride_status_schema_requires_status() -> Result[Unit, Str] {
  let bad := JObj([("booking_id", JStr("B-100"))])
  match schema_of("update_ride_status") {
    None => Err("update_ride_status tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("update_ride_status's schema must require status"),
    },
  }
}

fn test_get_ride_status_schema_requires_booking_id() -> Result[Unit, Str] {
  match schema_of("get_ride_status") {
    None => Err("get_ride_status tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_ride_status's schema must require booking_id"),
    },
  }
}

fn test_no_dsr_or_aiact_tools_exposed() -> Result[Unit, Str] {
  let names := list.map(agent.make_passenger_tools("http://127.0.0.1:8100"), fn (tool :: t.Tool) -> Str {
    tool.name
  })
  assert_true(list.is_empty(list.filter(names, fn (n :: Str) -> Bool {
    n == "dsr_export" or n == "dsr_erase" or n == "oversight"
  })), "GDPR data-subject-rights and AI Act human-oversight routes must not be exposed as agent tools")
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_six_tools_defined(), test_book_ride_schema_accepts_documented_shape(), test_dispatch_ride_schema_accepts_without_optional_params(), test_update_ride_status_schema_requires_status(), test_get_ride_status_schema_requires_booking_id(), test_no_dsr_or_aiact_tools_exposed()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

