# dispatch.lex — real-time on-demand matching core (lex-ev-fleet#167), pure.
#
# On-demand (taxi, dynamic last-mile) is the one model the planned-assignment and
# relay spine don't cover: a rider appears now, and the nearest free vehicle must
# be found in sub-minute time. This module is the matching math — great-circle
# distance from the pickup to each live vehicle, an approach-ETA, and a ranked
# shortlist within a radius. Pure (no I/O) so it unit-tests directly; the live
# fleet fetch (from lex-telemetry #168's /positions/latest) + persistence + HTTP
# live in dispatch_http.lex.
#
# Pooling (two riders sharing one vehicle) is deliberately out of scope for v0 —
# this is nearest-vehicle assignment. Availability is assumed: every vehicle in
# the snapshot is a candidate (a status/occupancy feed is a follow-up).

import "std.list" as list

import "std.math" as math

import "lex-schema/json_value" as jv

type Cand = { vehicle_ref :: Str, lat :: Float, lon :: Float, speed_kmh :: Float }

type Offer = { vehicle_ref :: Str, distance_km :: Float, eta_min :: Float }

fn pi() -> Float {
  3.141592653589793
}

fn earth_km() -> Float {
  6371.0
}

fn to_rad(d :: Float) -> Float {
  d * pi() / 180.0
}

fn r2(x :: Float) -> Float {
  math.round(x * 100.0) / 100.0
}

# Great-circle distance between two lat/lon points, in kilometres (haversine).
fn haversine_km(lat1 :: Float, lon1 :: Float, lat2 :: Float, lon2 :: Float) -> Float {
  let dlat := to_rad(lat2 - lat1)
  let dlon := to_rad(lon2 - lon1)
  let slat := math.sin(dlat / 2.0)
  let slon := math.sin(dlon / 2.0)
  let a := slat * slat + math.cos(to_rad(lat1)) * math.cos(to_rad(lat2)) * slon * slon
  let c := 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
  earth_km() * c
}

# Approach time in minutes at an assumed cruise speed. A parked vehicle still
# drives to the pickup, so the ride's approach uses cruise_kmh, not the vehicle's
# instantaneous speed; guard a non-positive cruise with a nominal urban 30 km/h.
fn eta_minutes(distance_km :: Float, cruise_kmh :: Float) -> Float {
  let s := if cruise_kmh <= 0.0 {
    30.0
  } else {
    cruise_kmh
  }
  distance_km / s * 60.0
}

fn score_offer(pickup_lat :: Float, pickup_lon :: Float, cand :: Cand, cruise_kmh :: Float) -> Offer {
  let d := haversine_km(pickup_lat, pickup_lon, cand.lat, cand.lon)
  { vehicle_ref: cand.vehicle_ref, distance_km: d, eta_min: eta_minutes(d, cruise_kmh) }
}

fn take_n(xs :: List[Offer], n :: Int) -> List[Offer] {
  list.map(list.filter(list.enumerate(xs), fn (p :: (Int, Offer)) -> Bool {
    match p {
      (i, _) => i < n,
    }
  }), fn (p :: (Int, Offer)) -> Offer {
    match p {
      (_, o) => o,
    }
  })
}

# Rank the live fleet for a pickup: score every candidate, drop those beyond
# radius_km, sort nearest-first, keep the top k. The shortlist an on-demand
# dispatcher offers out (or auto-assigns the head of).
fn rank(pickup_lat :: Float, pickup_lon :: Float, cands :: List[Cand], radius_km :: Float, cruise_kmh :: Float, k :: Int) -> List[Offer] {
  let scored := list.map(cands, fn (c :: Cand) -> Offer {
    score_offer(pickup_lat, pickup_lon, c, cruise_kmh)
  })
  let within := list.filter(scored, fn (o :: Offer) -> Bool {
    o.distance_km <= radius_km
  })
  let sorted := list.sort_by(within, fn (o :: Offer) -> Float {
    o.distance_km
  })
  take_n(sorted, k)
}

# The single best (nearest) vehicle within radius, or None if the fleet is empty
# or all vehicles are out of range.
fn best(pickup_lat :: Float, pickup_lon :: Float, cands :: List[Cand], radius_km :: Float, cruise_kmh :: Float) -> Option[Offer] {
  list.head(rank(pickup_lat, pickup_lon, cands, radius_km, cruise_kmh, 1))
}

fn offer_to_json(o :: Offer) -> jv.Json {
  JObj([("vehicle_ref", JStr(o.vehicle_ref)), ("distance_km", JFloat(r2(o.distance_km))), ("eta_min", JFloat(r2(o.eta_min)))])
}

fn offers_json(os :: List[Offer]) -> Str {
  jv.stringify(JObj([("count", JInt(list.len(os))), ("offers", JList(list.map(os, offer_to_json)))]))
}

