-- ============================================================
-- Monopoly Banker — Supabase schema
-- Run in your Supabase project: Dashboard → SQL Editor → paste → Run.
-- Safe to re-run (everything is idempotent).
-- ============================================================

-- ---------- games ----------
create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Untitled game',
  state jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.games add column if not exists user_id uuid default auth.uid();
create index if not exists games_user_idx on public.games(user_id);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists games_touch on public.games;
create trigger games_touch before update on public.games
for each row execute function public.touch_updated_at();

alter table public.games enable row level security;
drop policy if exists "anon full access" on public.games;
drop policy if exists "owners full access" on public.games;
create policy "owners full access" on public.games
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- players (roster reused across games) ----------
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  name text not null,
  color text,
  last_played_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, name)
);
alter table public.players add column if not exists token text;
create index if not exists players_user_idx on public.players(user_id);

alter table public.players enable row level security;
drop policy if exists "owners full access" on public.players;
create policy "owners full access" on public.players
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- game_stats (one row per player per game) ----------
create table if not exists public.game_stats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  game_id uuid not null references public.games(id) on delete cascade,
  game_name text,
  player_name text not null,
  color text,

  -- results & money
  rank int,
  won boolean not null default false,
  bankrupt boolean not null default false,
  cash numeric not null default 0,
  net_worth numeric not null default 0,

  -- property & building
  props int not null default 0,
  monopolies int not null default 0,
  houses int not null default 0,
  hotels int not null default 0,
  mortgaged int not null default 0,
  props_bought int not null default 0,
  times_mortgaged int not null default 0,

  -- money flow
  rent_collected numeric not null default 0,
  rent_paid numeric not null default 0,
  taxes_paid numeric not null default 0,
  go_collected numeric not null default 0,
  property_spend numeric not null default 0,
  building_spend numeric not null default 0,
  paid_to_players numeric not null default 0,
  received_from_players numeric not null default 0,
  biggest_rent_collected numeric not null default 0,
  biggest_rent_paid numeric not null default 0,

  -- game meta
  finished boolean not null default false,
  player_count int,
  starting_cash numeric,
  go_amount numeric,
  free_parking boolean,
  started_at timestamptz,
  ended_at timestamptz,
  duration_seconds int,
  updated_at timestamptz not null default now(),

  unique (game_id, player_name)
);
alter table public.game_stats add column if not exists token text;
create index if not exists game_stats_user_idx on public.game_stats(user_id);
create index if not exists game_stats_player_idx on public.game_stats(user_id, player_name);

alter table public.game_stats enable row level security;
drop policy if exists "owners full access" on public.game_stats;
create policy "owners full access" on public.game_stats
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- the trigger that keeps roster + stats in sync ----------
-- The app writes a "standings" array into games.state on every save.
-- This unpacks it into the roster and the stats table automatically.
create or replace function public.sync_game_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s jsonb;
  meta jsonb;
begin
  if new.user_id is null then return new; end if;
  meta := coalesce(new.state->'meta', '{}'::jsonb);

  for s in select * from jsonb_array_elements(coalesce(new.state->'standings', '[]'::jsonb))
  loop
    -- roster
    insert into public.players (user_id, name, color, token, last_played_at)
    values (new.user_id, s->>'name', s->>'color', s->>'token', now())
    on conflict (user_id, name) do update
      set color = excluded.color,
          token = coalesce(excluded.token, public.players.token),
          last_played_at = now();

    -- per-game stats
    insert into public.game_stats (
      user_id, game_id, game_name, player_name, color, token,
      rank, won, bankrupt, cash, net_worth,
      props, monopolies, houses, hotels, mortgaged, props_bought, times_mortgaged,
      rent_collected, rent_paid, taxes_paid, go_collected,
      property_spend, building_spend, paid_to_players, received_from_players,
      biggest_rent_collected, biggest_rent_paid,
      finished, player_count, starting_cash, go_amount, free_parking,
      started_at, ended_at, duration_seconds, updated_at
    ) values (
      new.user_id, new.id, new.name, s->>'name', s->>'color', s->>'token',
      (s->>'rank')::int, (s->>'won')::boolean, (s->>'bankrupt')::boolean,
      (s->>'cash')::numeric, (s->>'netWorth')::numeric,
      (s->>'props')::int, (s->>'monopolies')::int, (s->>'houses')::int,
      (s->>'hotels')::int, (s->>'mortgaged')::int,
      (s->>'propsBought')::int, (s->>'timesMortgaged')::int,
      (s->>'rentCollected')::numeric, (s->>'rentPaid')::numeric,
      (s->>'taxesPaid')::numeric, (s->>'goCollected')::numeric,
      (s->>'propertySpend')::numeric, (s->>'buildingSpend')::numeric,
      (s->>'paidToPlayers')::numeric, (s->>'receivedFromPlayers')::numeric,
      (s->>'biggestRentCollected')::numeric, (s->>'biggestRentPaid')::numeric,
      coalesce((meta->>'finished')::boolean, false),
      (meta->>'playerCount')::int, (meta->>'startingCash')::numeric,
      (meta->>'goAmount')::numeric, (meta->>'freeParking')::boolean,
      to_timestamp((meta->>'startedAt')::bigint / 1000.0),
      case when meta->>'endedAt' is null then null
           else to_timestamp((meta->>'endedAt')::bigint / 1000.0) end,
      (meta->>'durationSeconds')::int,
      now()
    )
    on conflict (game_id, player_name) do update set
      game_name = excluded.game_name,
      color = excluded.color,
      token = excluded.token,
      rank = excluded.rank,
      won = excluded.won,
      bankrupt = excluded.bankrupt,
      cash = excluded.cash,
      net_worth = excluded.net_worth,
      props = excluded.props,
      monopolies = excluded.monopolies,
      houses = excluded.houses,
      hotels = excluded.hotels,
      mortgaged = excluded.mortgaged,
      props_bought = excluded.props_bought,
      times_mortgaged = excluded.times_mortgaged,
      rent_collected = excluded.rent_collected,
      rent_paid = excluded.rent_paid,
      taxes_paid = excluded.taxes_paid,
      go_collected = excluded.go_collected,
      property_spend = excluded.property_spend,
      building_spend = excluded.building_spend,
      paid_to_players = excluded.paid_to_players,
      received_from_players = excluded.received_from_players,
      biggest_rent_collected = excluded.biggest_rent_collected,
      biggest_rent_paid = excluded.biggest_rent_paid,
      finished = excluded.finished,
      player_count = excluded.player_count,
      starting_cash = excluded.starting_cash,
      go_amount = excluded.go_amount,
      free_parking = excluded.free_parking,
      started_at = excluded.started_at,
      ended_at = excluded.ended_at,
      duration_seconds = excluded.duration_seconds,
      updated_at = now();
  end loop;

  return new;
end $$;

drop trigger if exists games_sync_stats on public.games;
create trigger games_sync_stats after insert or update on public.games
for each row execute function public.sync_game_stats();

-- ---------- leaderboard ----------
drop view if exists public.player_leaderboard;
create view public.player_leaderboard
with (security_invoker = on) as
select
  user_id,
  player_name,
  max(color) filter (where color is not null)          as color,
  max(token) filter (where token is not null)          as token,
  count(*) filter (where finished)                     as games,
  count(*) filter (where finished and won)             as wins,
  round(
    100.0 * count(*) filter (where finished and won)
    / nullif(count(*) filter (where finished), 0)
  , 0)                                                 as win_pct,
  count(*) filter (where not finished)                 as in_progress,
  round(avg(net_worth) filter (where finished), 0)     as avg_net_worth,
  max(net_worth) filter (where finished)               as best_net_worth,
  sum(rent_collected)                                  as rent_collected,
  sum(rent_paid)                                       as rent_paid,
  sum(props_bought)                                    as props_bought,
  sum(houses + hotels)                                 as built,
  max(biggest_rent_collected)                          as biggest_rent_collected,
  max(updated_at)                                      as last_played_at
from public.game_stats
group by user_id, player_name;
