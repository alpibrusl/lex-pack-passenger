# aiact.lex — EU AI Act classification + disclosure for gig dispatch (lex-ev-fleet#172), pure.
#
# The real-time dispatch/matching engine (#167) ranks and assigns work to gig
# drivers automatically. Under the EU AI Act that is an Annex III point-4 system
# ("employment, workers management and access to self-employment" — algorithmic
# task allocation and monitoring of persons who perform platform work), i.e.
# HIGH-RISK. This module is the pure, machine-readable disclosure of that fact:
# the classification, the automated-decision flag, the actual ranking parameters
# the engine uses, the human-oversight measures, and the affected worker's rights.
#
# This is engineering scaffolding for the DPO/compliance function, not legal
# advice. The oversight surface + decision log live in aiact_http.lex.

import "std.list" as list

import "lex-schema/json_value" as jv

fn system_name() -> Str {
  "real-time-gig-dispatch"
}

# Annex III(4): worker management. Kept as a value so callers can branch on it.
fn annex_iii_role() -> Str {
  "annex_iii_point_4_worker_management"
}

fn str_arr(xs :: List[Str]) -> jv.Json {
  JList(list.map(xs, fn (s :: Str) -> jv.Json {
    JStr(s)
  }))
}

# The main ranking parameters the dispatch engine (#167) actually applies, named
# so the disclosure is truthful about how allocation decisions are reached.
fn ranking_parameters() -> List[Str] {
  ["great_circle_distance_from_pickup", "estimated_time_of_arrival", "search_radius_km", "nearest_first_ordering"]
}

# The human-oversight measures in place (AI Act Art. 14): a supervisor can review,
# override, or uphold any automated assignment, and every automated decision and
# every oversight action is logged (Art. 12 record-keeping).
fn oversight_measures() -> List[Str] {
  ["human_review_available", "human_override_of_assignment", "worker_contest_channel", "immutable_decision_and_oversight_log"]
}

# What an affected worker is entitled to (Art. 14 oversight + GDPR Art. 22
# automated-decision rights): to be told, to a human review, and to contest.
fn affected_person_rights() -> List[Str] {
  ["informed_decision_is_automated", "obtain_human_intervention", "contest_the_assignment", "explanation_of_main_parameters"]
}

# The full disclosure ("system card") as a structured document.
fn system_card() -> jv.Json {
  JObj([("system", JStr(system_name())), ("risk_classification", JStr("high_risk")), ("legal_basis", JStr(annex_iii_role())), ("automated_decision", JBool(true)), ("purpose", JStr("real-time allocation of transport jobs to available gig drivers")), ("affected_persons", JStr("gig / platform-work drivers")), ("ranking_parameters", str_arr(ranking_parameters())), ("human_oversight", str_arr(oversight_measures())), ("affected_person_rights", str_arr(affected_person_rights())), ("logging", JStr("every automated assignment and every human oversight action is recorded on the tamper-evident trail")), ("disclaimer", JStr("engineering compliance metadata for the DPO/compliance function; not legal advice"))])
}

fn disclosure_json() -> Str {
  jv.stringify(system_card())
}

# A human-oversight action over an automated decision. `uphold` affirms the
# automated assignment; `override` replaces it; `contest` is a worker-raised
# challenge awaiting review.
fn valid_oversight_action(action :: Str) -> Bool {
  action == "uphold" or action == "override" or action == "contest"
}

