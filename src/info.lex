# info.lex — the passenger agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the passenger-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "passenger", title: "Passenger", tagline: "On-demand mobility: rider bookings, live-fleet dispatch, and ride orchestration.", personas: [{ kind: "passenger-ops", title: "Passenger ops", tagline: "Registers riders, books and dispatches rides, and tracks status through payment.", suggested_prompts: ["Register a rider named Alex.", "Book a ride for rider R-100 from 52.37,4.90 to 52.40,4.89, about 5km and 15 minutes.", "Dispatch booking B-100.", "What is the status of booking B-100?", "Record payment for booking B-100, ref PAY-1."] }] }
}

