-- ============================================================================
--  LUCKY DRAW — Part 4 (add-on) : self-scan booths + entrance
-- ============================================================================
--  Run this AFTER 01, 02 and 03 have already been run once, against the same
--  Supabase project. It is idempotent — re-running is safe.
--
--  What this adds:
--   - A "scan spot" is any fixed QR code you print and stick up somewhere
--     (the entrance, or one of your 100 booths). Each has its own `code`
--     (e.g. 'ENTRANCE', 'BOOTH-001' ... 'BOOTH-100') and its own point value.
--   - A logged-in customer scans a spot's QR with THEIR OWN phone, inside
--     this app. One ticket-earning scan per spot per person every 24 real
--     hours (a rolling window, not "once per calendar day").
--   - This does NOT touch the existing front-desk check-in feature
--     (checkins / xf_admin_checkin_scan). That still exists if you ever want
--     staff-scanned check-ins later; it is simply unused by this flow.
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
--  TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- The registry of valid spots: the entrance, and every booth.
create table if not exists scan_codes (
  code        text        primary key,   -- e.g. 'ENTRANCE', 'BOOTH-001'
  label       text        not null,      -- shown to the customer, e.g. 'Booth 1'
  points      integer     not null default 1 check (points >= 0),
  active      boolean     not null default true,
  created_at  timestamptz not null default now()
);

-- One row per successful scan. A person can scan the same code again on a
-- LATER CALENDAR DAY and get another row (and another ticket) — this table
-- is a log, not a "have they ever scanned this" flag.
--
-- scan_date is the calendar date in the event's configured timezone
-- (app_config.timezone, default Asia/Kuala_Lumpur), NOT UTC. It is stored
-- rather than computed on read, because `now() at time zone <a setting>` is
-- not immutable and so cannot be indexed. The unique constraint on
-- (participant_id, code, scan_date) is what actually enforces the
-- once-per-booth-per-day rule: even if a customer double-taps and two
-- requests land at the same instant, the database rejects the second.
create table if not exists scan_claims (
  id             bigserial   primary key,
  participant_id bigint      not null references participants(id) on delete cascade,
  code           text        not null references scan_codes(code),
  scan_date      date        not null default (now() at time zone 'Asia/Kuala_Lumpur')::date,
  created_at     timestamptz not null default now()
);

-- If an earlier version of this file already created the table without
-- scan_date, add it and backfill from created_at.
alter table scan_claims add column if not exists scan_date date;
update scan_claims
   set scan_date = (created_at at time zone coalesce(
                     (select value from app_config where key = 'timezone'),
                     'Asia/Kuala_Lumpur'))::date
 where scan_date is null;
alter table scan_claims alter column scan_date set not null;

create unique index if not exists scan_claims_once_per_day
  on scan_claims (participant_id, code, scan_date);

-- Same lockdown pattern as every other table in 01_schema.sql: nothing here
-- is reachable directly from the REST API, only through checked functions.
revoke all on scan_codes  from anon, authenticated;
revoke all on scan_claims from anon, authenticated;
alter table scan_codes  enable row level security;
alter table scan_codes  force  row level security;
alter table scan_claims enable row level security;
alter table scan_claims force  row level security;
revoke usage on sequence scan_claims_id_seq from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  HELPER
-- ═══════════════════════════════════════════════════════════════════════════

-- Accepts the raw text a QR scanner reads and turns it into a bare code.
-- Printed QRs encode 'LDSCAN:BOOTH-007'; this strips that prefix (case
-- insensitive) and uppercases, so a customer's camera reading either
-- 'LDSCAN:booth-007' or a manually typed 'booth-007' both resolve the same.
create or replace function xf_norm_scan_code(p_code text)
returns text language sql immutable as $$
  select upper(regexp_replace(btrim(coalesce(p_code, '')), '^LDSCAN:', '', 'i'))
$$;

-- ═══════════════════════════════════════════════════════════════════════════
--  xf_ticket_counts — add a "scan" bucket
--  (return columns change, so this needs DROP, not just CREATE OR REPLACE)
-- ═══════════════════════════════════════════════════════════════════════════
drop function if exists xf_ticket_counts(bigint);

create function xf_ticket_counts(p_id bigint)
returns table (checkin integer, renewal integer, social integer,
               repost integer, adjust integer, scan integer, total integer)
language sql stable security definer set search_path = public as $$
  with
  c as (select least(count(*), xf_cfg_int('checkin_max_days', 7))
               * xf_cfg_int('checkin_pts_per_day', 3) as n
          from checkins where participant_id = p_id),
  r as (select case when xf_cfg_int('renewal_max_months', 0) > 0
                    then least(coalesce(max(months), 0), xf_cfg_int('renewal_max_months', 0))
                    else coalesce(max(months), 0) end
               * xf_cfg_int('renewal_pts_per_month', 1) as n
          from renewals where participant_id = p_id),
  s as (select count(*) * xf_cfg_int('social_points', 3) as n
          from claims where participant_id = p_id
           and platform <> 'repost' and status = 'approved'),
  p as (select count(*) * xf_cfg_int('repost_points', 6) as n
          from claims where participant_id = p_id
           and platform = 'repost' and status = 'approved'),
  a as (select coalesce(sum(delta), 0) as n
          from ticket_adjustments where participant_id = p_id),
  sc as (select coalesce(sum(sco.points), 0) as n
           from scan_claims scl
           join scan_codes  sco on sco.code = scl.code
          where scl.participant_id = p_id)
  select c.n::int, r.n::int, s.n::int, p.n::int, a.n::int, sc.n::int,
         greatest(0, (c.n + r.n + s.n + p.n + a.n + sc.n))::int
    from c, r, s, p, a, sc
$$;

-- DROP wipes the ACL. This table's whole security model is "internal
-- helpers are granted to nobody" — put that back immediately.
revoke all on function xf_ticket_counts(bigint) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  xf_issue_tickets — add the "scan" source to the pool rebuild
--  (same signature as before, so CREATE OR REPLACE keeps its existing ACL)
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function xf_issue_tickets()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n bigint; v_max bigint;
begin
  if xf_pool_locked() then
    select count(*), coalesce(max(serial), 0) into v_n, v_max from draw_tickets;
    return jsonb_build_object('ok', true, 'locked', true,
                              'issued', v_n, 'max_serial', v_max);
  end if;

  delete from draw_tickets where true;   -- WHERE required: safeupdate

  insert into draw_tickets (serial, participant_id, source, detail, earned_at)
  select row_number() over (
           order by src.earned_at,
                    md5(src.participant_id::text || '|' || src.source || '|' ||
                        src.detail || '|' || src.k::text)),
         src.participant_id, src.source, src.detail, src.earned_at
  from (
    select c.participant_id, 'checkin'::text as source,
           c.visit_date::text as detail, c.created_at as earned_at, k
      from (select participant_id, visit_date, created_at,
                   row_number() over (partition by participant_id order by visit_date) as rn
              from checkins) c
     cross join generate_series(1, xf_cfg_int('checkin_pts_per_day', 3)) k
     where c.rn <= xf_cfg_int('checkin_max_days', 7)

    union all
    select r.participant_id, 'renewal', 'month ' || g::text, r.updated_at,
           (g * 1000 + k)
      from renewals r
     cross join lateral generate_series(1,
            case when xf_cfg_int('renewal_max_months', 0) > 0
                 then least(r.months, xf_cfg_int('renewal_max_months', 0))
                 else r.months end) g
     cross join generate_series(1, xf_cfg_int('renewal_pts_per_month', 1)) k

    union all
    select cl.participant_id, 'social', cl.platform, cl.created_at, k
      from claims cl
     cross join generate_series(1, xf_cfg_int('social_points', 3)) k
     where cl.platform <> 'repost' and cl.status = 'approved'

    union all
    select cl.participant_id, 'repost', '', cl.created_at, k
      from claims cl
     cross join generate_series(1, xf_cfg_int('repost_points', 6)) k
     where cl.platform = 'repost' and cl.status = 'approved'

    union all
    select ta.participant_id, 'adjust', ta.reason, ta.created_at, k
      from ticket_adjustments ta
     cross join lateral generate_series(1, ta.delta) k
     where ta.delta > 0

    union all
    -- one row per scan, expanded to that spot's point value, each copy made
    -- distinct for the tie-break hash by k
    select scl.participant_id, 'scan'::text, scl.code, scl.created_at, k
      from scan_claims scl
      join scan_codes  sco on sco.code = scl.code
     cross join lateral generate_series(1, greatest(sco.points, 1)) k
     where sco.points > 0
  ) src
  join participants pt on pt.id = src.participant_id
  where not pt.disqualified;

  select count(*), coalesce(max(serial), 0) into v_n, v_max from draw_tickets;
  return jsonb_build_object('ok', true, 'locked', false,
                            'issued', v_n, 'max_serial', v_max);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  xf_me_payload — surface the scan bucket + a short scan history
--  (same signature as before, so CREATE OR REPLACE keeps its existing ACL)
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function xf_me_payload(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p participants%rowtype; t record; v jsonb;
begin
  select * into p from participants where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into t from xf_ticket_counts(p_id);

  v := jsonb_build_object(
    'ok', true,
    'name', p.full_name,
    'ic_last4', p.ic_last4,
    'platform', p.platform,
    'disqualified', p.disqualified,
    'qr', 'LD1:' || p.qr_token::text,
    'tickets', jsonb_build_object(
      'total', t.total, 'checkin', t.checkin, 'renewal', t.renewal,
      'social', t.social, 'repost', t.repost, 'adjust', t.adjust,
      'scan', t.scan),
    'checkin_dates', coalesce((select jsonb_agg(visit_date::text order by visit_date)
                                 from checkins where participant_id = p_id), '[]'::jsonb),
    'social', coalesce((select jsonb_object_agg(platform, true)
                          from claims where participant_id = p_id
                           and platform <> 'repost' and status = 'approved'), '{}'::jsonb),
    'repost', coalesce((select status from claims
                         where participant_id = p_id and platform = 'repost'), 'none'),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object(
                              'delta', delta, 'reason', reason,
                              'at', to_char(created_at at time zone xf_tz(), 'DD Mon YYYY'))
                              order by created_at)
                              from ticket_adjustments where participant_id = p_id), '[]'::jsonb),
    -- last 30 scans, most recent first — enough for the customer to see their
    -- own booth crawl without the payload growing unbounded over 8 days
    'scans', coalesce((select jsonb_agg(row_to_json(x))
                          from (select sco.label, scl.code,
                                       to_char(scl.created_at at time zone xf_tz(),
                                               'DD Mon, HH24:MI') as at
                                  from scan_claims scl
                                  join scan_codes  sco on sco.code = scl.code
                                 where scl.participant_id = p_id
                                 order by scl.created_at desc
                                 limit 30) x), '[]'::jsonb),
    'prize', (select jsonb_build_object(
                'tier', w.tier, 'name', pz.name, 'subtitle', pz.subtitle,
                'claimed', w.claimed,
                'claimed_at', to_char(w.claimed_at at time zone xf_tz(), 'DD Mon YYYY'))
                from winners w join prizes pz on pz.tier = w.tier
               where w.participant_id = p_id)
  );
  return v;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  xf_scan — the new public function. This is what the customer's own
--  phone calls when their camera reads a booth or entrance QR.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function xf_scan(p_ic text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id bigint; v_code text; v_points int; v_label text; v_today date;
begin
  select id into v_id from participants where ic_hash = xf_hash_ic(p_ic);
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if xf_pool_locked() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if exists (select 1 from participants where id = v_id and disqualified) then
    return jsonb_build_object('ok', false, 'error', 'disqualified');
  end if;

  v_code := xf_norm_scan_code(p_code);
  select points, label into v_points, v_label
    from scan_codes where code = v_code and active;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;

  -- xf_today() is "today" in the event's configured timezone, so the day
  -- rolls over at local midnight, not UTC midnight.
  v_today := xf_today();

  if exists (select 1 from scan_claims
              where participant_id = v_id and code = v_code
                and scan_date = v_today) then
    return jsonb_build_object('ok', false, 'error', 'already_today',
                              'label', v_label);
  end if;

  -- ON CONFLICT covers the double-tap race the check above cannot: two
  -- simultaneous requests both pass the EXISTS, only one row survives.
  insert into scan_claims (participant_id, code, scan_date)
  values (v_id, v_code, v_today)
  on conflict (participant_id, code, scan_date) do nothing;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'already_today',
                              'label', v_label);
  end if;

  perform xf_issue_tickets();

  return xf_me_payload(v_id) || jsonb_build_object(
    'scanned', v_label, 'scan_points', v_points);
end $$;

grant execute on function xf_scan(text, text) to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  SEED DATA — the entrance + 100 booths
--  Edit the point values below before your event if you don't want
--  3 / entrance-scan and 1 / booth-scan. Safe to re-run: existing codes are
--  left untouched, only missing ones are added.
-- ═══════════════════════════════════════════════════════════════════════════
insert into scan_codes (code, label, points) values
  ('ENTRANCE', 'Event entrance', 3)
on conflict (code) do nothing;

insert into scan_codes (code, label, points)
select 'BOOTH-' || lpad(n::text, 3, '0'), 'Booth ' || n, 1
  from generate_series(1, 100) n
on conflict (code) do nothing;

notify pgrst, 'reload schema';
