# tests/test_passenger_http.lex — manifest coverage for src/passenger_http.lex.
#
# This is the ONE manifest for the whole on-demand-mobility flow this pack
# folds together (booking, dispatch, ride orchestration, DSR, AI Act) — the
# other modules mount their own routes but don't declare a second manifest.
# The effectful routes need a live DB to exercise meaningfully — that's
# covered by lex-ev-fleet's own integration testing of the mounted deployment.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/passenger_http" as passenger_http

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

fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := passenger_http.manifest()
  assert_true(list.is_empty(pos.validate(m)), "passenger's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(passenger_http.manifest().route_prefix == "/passenger", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_settles() -> Result[Unit, Str] {
  assert_true(passenger_http.manifest().settles, "the PSP hand-off settles the rider's fare, so the manifest must declare settles: true")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_settles()]
}

