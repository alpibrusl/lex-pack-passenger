# aiact_http.lex — AI Act transparency + human-oversight surface over gig dispatch (lex-ev-fleet#172).
#
# The classification + disclosure are pure (aiact.lex). This is the effectful
# boundary: it publishes the disclosure (Art. 13/50 transparency) and provides
# the Art. 14 human-oversight controls with Art. 12 record-keeping — a supervisor
# can uphold / override an automated assignment, or log a worker's contest, and
# every action is written to the tamper-evident trail and a queryable log.
#
#   GET  /aiact/dispatch/disclosure                the system card (public transparency)
#   POST /aiact/dispatch/:ride_ref/oversight       human oversight over an automated
#                                                  assignment { action, reviewer, reason }
#   GET  /aiact/dispatch/oversight                 the oversight audit log (per tenant)

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "./aiact" as aiact

type OversightRow = { id :: Str, ride_ref :: Str, action :: Str, reviewer :: Str, reason :: Str, created_ms :: Int }

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# BIGINT, not INTEGER: lex's Postgres driver binds PInt params as Rust i64,
# which tokio-postgres refuses to serialize against an INTEGER (int4) column
# — same client-side rejection as PFloat vs REAL; see reference_lex_postgres.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS dispatch_oversight (id TEXT NOT NULL PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'demo', ride_ref TEXT NOT NULL DEFAULT '', action TEXT NOT NULL DEFAULT '', reviewer TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL DEFAULT 0)", [])
  let __cm := sql.exec(db, "ALTER TABLE dispatch_oversight ALTER COLUMN created_ms TYPE BIGINT", [])
  ()
}

# Art. 13/50: the machine-readable disclosure that dispatch is an automated,
# high-risk (Annex III) worker-management system. Public — no auth.
fn handle_disclosure() -> resp.Response {
  resp.json(aiact.disclosure_json())
}

# Art. 14 human oversight + Art. 12 logging: a supervisor upholds/overrides an
# automated assignment, or a worker's contest is logged. Recorded in the
# oversight log and stamped on the tamper-evident trail.
fn handle_oversight(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "ride_ref") {
    None => resp.bad_request("{\"error\":\"missing ride_ref\"}"),
    Some(ride_ref) => match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let action := jstr(j, "action")
        if not aiact.valid_oversight_action(action) {
          resp.bad_request("{\"error\":\"action must be one of: uphold, override, contest\"}")
        } else {
          let reviewer := jstr(j, "reviewer")
          if str.is_empty(reviewer) {
            resp.bad_request("{\"error\":\"reviewer is required\"}")
          } else {
            let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
            let now := time.now_ms()
            let oid := str.concat("ovs-", int.to_str(now))
            let reason := jstr(j, "reason")
            match sql.exec(db, "INSERT INTO dispatch_oversight (id, tenant, ride_ref, action, reviewer, reason, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?)", [PStr(oid), PStr(tenant), PStr(ride_ref), PStr(action), PStr(reviewer), PStr(reason), PInt(now)]) {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
              Ok(_) => {
                let log := settlement.trail_on(db)
                let __e := tlog.append(log, "aiact.oversight", None, jv.stringify(JObj([("oversight_id", JStr(oid)), ("ride_ref", JStr(ride_ref)), ("action", JStr(action)), ("reviewer", JStr(reviewer)), ("tenant", JStr(tenant)), ("system", JStr(aiact.system_name())), ("at_ms", JInt(now))])))
                resp.json_status(201, jv.stringify(JObj([("oversight_id", JStr(oid)), ("ride_ref", JStr(ride_ref)), ("action", JStr(action)), ("reviewer", JStr(reviewer))])))
              },
            }
          }
        }
      },
    },
  }
}

fn oversight_to_json(r :: OversightRow) -> jv.Json {
  JObj([("oversight_id", JStr(r.id)), ("ride_ref", JStr(r.ride_ref)), ("action", JStr(r.action)), ("reviewer", JStr(r.reviewer)), ("reason", JStr(r.reason)), ("created_ms", JInt(r.created_ms))])
}

fn handle_list_oversight(c :: ctx.Ctx, db :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  let tenant := ctx.header_or(c, "X-Tenant-Id", "demo")
  let rows :: Result[List[OversightRow], SqlError] := sql.query(db, "SELECT id, ride_ref, action, reviewer, reason, created_ms FROM dispatch_oversight WHERE tenant = ? ORDER BY created_ms DESC LIMIT 200", [PStr(tenant)])
  match rows {
    Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
    Ok(rs) => resp.json(jv.stringify(JList(list.map(rs, oversight_to_json)))),
  }
}

fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let r_disc := router.route_effectful(r, "GET", "/aiact/dispatch/disclosure", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_disclosure()
  })
  let r_ovs := router.route_effectful(r_disc, "POST", "/aiact/dispatch/:ride_ref/oversight", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_oversight(c, db)
  })
  router.route_effectful(r_ovs, "GET", "/aiact/dispatch/oversight", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list_oversight(c, db)
  })
}

