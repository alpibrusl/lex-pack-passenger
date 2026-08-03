# tests/test_dispatch.lex — the on-demand matching core (src/dispatch.lex).
#
# Great-circle distance, approach-ETA (incl. the parked-vehicle cruise guard),
# and radius-filtered nearest-first ranking.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "../src/dispatch" as dispatch

fn expect(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn near(a :: Float, b :: Float, tol :: Float) -> Bool {
  let d := a - b
  if d < 0.0 {
    0.0 - d <= tol
  } else {
    d <= tol
  }
}

# One degree of longitude at the equator is ~111.19 km.
fn haversine_equator_degree() -> Result[Unit, Str] {
  expect("1 deg lon at equator ~= 111.19 km", near(dispatch.haversine_km(0.0, 0.0, 0.0, 1.0), 111.19, 0.5))
}

fn eta_basic() -> Result[Unit, Str] {
  expect("30 km at 30 km/h = 60 min", near(dispatch.eta_minutes(30.0, 30.0), 60.0, 0.001))
}

# A non-positive cruise speed falls back to the nominal 30 km/h.
fn eta_cruise_guard() -> Result[Unit, Str] {
  expect("10 km at guarded 30 km/h = 20 min", near(dispatch.eta_minutes(10.0, 0.0), 20.0, 0.001))
}

fn fleet() -> List[dispatch.Cand] {
  [{ vehicle_ref: "A", lat: 0.0, lon: 0.08, speed_kmh: 0.0 }, { vehicle_ref: "B", lat: 0.0, lon: 0.045, speed_kmh: 0.0 }, { vehicle_ref: "C", lat: 0.0, lon: 2.0, speed_kmh: 0.0 }]
}

# C is ~222 km out (beyond the 10 km radius); B (~5 km) beats A (~8.9 km).
fn rank_filters_and_orders() -> Result[Unit, Str] {
  let offers := dispatch.rank(0.0, 0.0, fleet(), 10.0, 30.0, 5)
  let first := match list.head(offers) {
    Some(o) => o.vehicle_ref,
    None => "",
  }
  expect("radius drops C, nearest B ranks first", list.len(offers) == 2 and first == "B")
}

fn best_picks_nearest() -> Result[Unit, Str] {
  let who := match dispatch.best(0.0, 0.0, fleet(), 10.0, 30.0) {
    Some(o) => o.vehicle_ref,
    None => "none",
  }
  expect("best is the nearest in range (B)", who == "B")
}

fn best_empty_is_none() -> Result[Unit, Str] {
  let none := match dispatch.best(0.0, 0.0, [], 10.0, 30.0) {
    Some(_) => false,
    None => true,
  }
  expect("empty fleet yields no match", none)
}

fn run_all() -> [io] Unit {
  let results := [haversine_equator_degree(), eta_basic(), eta_cruise_guard(), rank_filters_and_orders(), best_picks_nearest(), best_empty_is_none()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __show := list.fold(failures, (), fn (_a :: Unit, m :: Str) -> [io] Unit {
      io.print(str.concat("FAIL: ", str.concat(m, "\n")))
    })
    let __boom := 1 / 0
    ()
  }
}

