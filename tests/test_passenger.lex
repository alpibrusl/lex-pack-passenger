# tests/test_passenger.lex — the passenger fare + lifecycle core (src/passenger.lex).
#
# Fare arithmetic (incl. the min-fare floor), the booking transition rules, and
# the terminal-state amounts (metered fare / no-show fee / nothing).

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "../src/passenger" as passenger

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

# default: base 2.5 + 1.1/km + 0.2/min; 10 km, 20 min = 2.5 + 11 + 4 = 17.5.
fn fare_metered() -> Result[Unit, Str] {
  expect("10 km / 20 min = 17.50", near(passenger.quote_fare(passenger.default_policy(), 10.0, 20.0), 17.5, 0.001))
}

# 0.1 km / 1 min = 2.81 raw, below the 4.0 floor.
fn fare_min_floor() -> Result[Unit, Str] {
  expect("short trip clamps to min_fare 4.0", near(passenger.quote_fare(passenger.default_policy(), 0.1, 1.0), 4.0, 0.001))
}

fn transitions_ok() -> Result[Unit, Str] {
  expect("booked->en_route allowed", passenger.can_transition("booked", "en_route"))
}

fn transitions_reject_skip() -> Result[Unit, Str] {
  expect("booked->completed rejected", not passenger.can_transition("booked", "completed"))
}

fn transitions_terminal() -> Result[Unit, Str] {
  expect("completed is terminal", not passenger.can_transition("completed", "en_route"))
}

fn amount_completed() -> Result[Unit, Str] {
  expect("completed charges the metered fare", near(passenger.final_amount(passenger.default_policy(), "completed", 10.0, 20.0), 17.5, 0.001))
}

fn amount_no_show() -> Result[Unit, Str] {
  expect("no_show charges the no-show fee", near(passenger.final_amount(passenger.default_policy(), "no_show", 10.0, 20.0), 5.0, 0.001))
}

fn amount_cancelled() -> Result[Unit, Str] {
  expect("cancelled charges nothing", near(passenger.final_amount(passenger.default_policy(), "cancelled", 10.0, 20.0), 0.0, 0.001))
}

fn run_all() -> [io] Unit {
  let results := [fare_metered(), fare_min_floor(), transitions_ok(), transitions_reject_skip(), transitions_terminal(), amount_completed(), amount_no_show(), amount_cancelled()]
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

