# passenger.lex — passenger domain core (lex-ev-fleet#169), pure.
#
# On-demand mobility introduces a new first-class actor the freight spine never
# had: the rider. This module is the pure part of that domain — the fare policy
# and quote arithmetic, and the booking lifecycle state machine (incl. no-shows).
# No I/O, so it unit-tests directly; rider/booking persistence, the B2C payment
# hand-off to a PSP, and HTTP live in passenger_http.lex.
#
# Money here is B2C fares (rider -> operator), deliberately separate from the B2B
# invoicing/settlement trail the freight side uses.

import "std.math" as math

import "lex-schema/json_value" as jv

type FarePolicy = { base :: Float, per_km :: Float, per_min :: Float, min_fare :: Float, no_show_fee :: Float, currency :: Str }

# A sensible urban default when a tenant hasn't set its own tariff.
fn default_policy() -> FarePolicy {
  { base: 2.5, per_km: 1.1, per_min: 0.2, min_fare: 4.0, no_show_fee: 5.0, currency: "EUR" }
}

fn round_money(x :: Float) -> Float {
  math.round(x * 100.0) / 100.0
}

# A distance + time tariff with a floor: max(min_fare, base + per_km + per_min).
fn quote_fare(p :: FarePolicy, distance_km :: Float, duration_min :: Float) -> Float {
  let raw := p.base + p.per_km * distance_km + p.per_min * duration_min
  round_money(math.max(p.min_fare, raw))
}

fn valid_status(s :: Str) -> Bool {
  s == "booked" or s == "en_route" or s == "completed" or s == "cancelled" or s == "no_show"
}

# Booking lifecycle: booked -> en_route -> completed, with cancel/no-show exits.
# completed/cancelled/no_show are terminal.
fn can_transition(from :: Str, to :: Str) -> Bool {
  if from == "booked" {
    to == "en_route" or to == "cancelled" or to == "no_show"
  } else {
    if from == "en_route" {
      to == "completed" or to == "cancelled"
    } else {
      false
    }
  }
}

# What the rider owes given the terminal state: the metered fare when the trip
# completes, the no-show fee when they don't show, nothing when cancelled early.
fn final_amount(p :: FarePolicy, status :: Str, distance_km :: Float, duration_min :: Float) -> Float {
  if status == "completed" {
    quote_fare(p, distance_km, duration_min)
  } else {
    if status == "no_show" {
      round_money(p.no_show_fee)
    } else {
      0.0
    }
  }
}

fn policy_to_json(p :: FarePolicy) -> jv.Json {
  JObj([("base", JFloat(p.base)), ("per_km", JFloat(p.per_km)), ("per_min", JFloat(p.per_min)), ("min_fare", JFloat(p.min_fare)), ("no_show_fee", JFloat(p.no_show_fee)), ("currency", JStr(p.currency))])
}

fn policy_json(p :: FarePolicy) -> Str {
  jv.stringify(policy_to_json(p))
}

