# tests/test_aiact.lex — the AI Act dispatch disclosure core (src/aiact.lex).
#
# The disclosure must truthfully carry the high-risk classification, the
# automated-decision flag, and the actual ranking parameters; the oversight
# action set must be exactly {uphold, override, contest}.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/aiact" as aiact

fn expect(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn field_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn field_bool(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn classified_high_risk() -> Result[Unit, Str] {
  expect("disclosure is high_risk + Annex III worker-management", field_str(aiact.system_card(), "risk_classification") == "high_risk" and field_str(aiact.system_card(), "legal_basis") == "annex_iii_point_4_worker_management")
}

fn flags_automated() -> Result[Unit, Str] {
  expect("disclosure flags automated decision", field_bool(aiact.system_card(), "automated_decision"))
}

# The disclosure must name the real parameters, so it can't claim to be truthful
# while listing none.
fn discloses_parameters() -> Result[Unit, Str] {
  expect("ranking parameters are disclosed", list.len(aiact.ranking_parameters()) >= 1 and not str.is_empty(aiact.disclosure_json()))
}

fn oversight_actions_exact() -> Result[Unit, Str] {
  expect("oversight actions are exactly uphold/override/contest", aiact.valid_oversight_action("uphold") and aiact.valid_oversight_action("override") and aiact.valid_oversight_action("contest") and not aiact.valid_oversight_action("delete") and not aiact.valid_oversight_action(""))
}

fn run_all() -> [io] Unit {
  let results := [classified_high_risk(), flags_automated(), discloses_parameters(), oversight_actions_exact()]
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

