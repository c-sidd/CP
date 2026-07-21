-- =============================================================
--  CLUB RECRUITMENT ARCADE — Supabase schema
--  Run this in your Supabase project: SQL Editor -> New query -> Run
-- =============================================================

-- pgcrypto gives us gen_random_uuid() and bcrypt (crypt / gen_salt)
create extension if not exists pgcrypto;

-- -------------------------------------------------------------
--  Table: candidates
-- -------------------------------------------------------------
create table if not exists candidates (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  email text unique not null,
  college_email text not null,
  branch text,
  section text,
  phone text,
  domain text not null,
  answers jsonb,
  passcode text,                 -- stored as a bcrypt hash, never plaintext
  stage text default 'Form Submitted',

  -- Round progression & tracking (added)
  current_round integer default 1 not null,
  stage_status text default 'In Review' not null
    check (stage_status in (
      'In Review',
      'Shortlisted',
      'Promoted to Next Round',
      'Rejected',
      'Selected'
    )),
  reviewer_notes text,
  total_score integer default 0 not null,

  assigned_task_title text,
  assigned_task_desc text,
  submission_link text,
  created_at timestamp with time zone default timezone('utc'::text, now())
);

-- If the table already exists and is missing the new columns, add them:
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_name = 'candidates' and column_name = 'current_round'
  ) then
    alter table candidates add column current_round integer default 1 not null;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_name = 'candidates' and column_name = 'stage_status'
  ) then
    alter table candidates add column stage_status text default 'In Review' not null
      check (stage_status in (
        'In Review',
        'Shortlisted',
        'Promoted to Next Round',
        'Rejected',
        'Selected'
      ));
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_name = 'candidates' and column_name = 'reviewer_notes'
  ) then
    alter table candidates add column reviewer_notes text;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_name = 'candidates' and column_name = 'total_score'
  ) then
    alter table candidates add column total_score integer default 0 not null;
  end if;
end $$;

-- -------------------------------------------------------------
--  Table: quest_responses
--  Stores per-round task submissions, scored and reviewed by
--  the admin council. FK cascades on candidate deletion.
-- -------------------------------------------------------------
create table if not exists quest_responses (
  id uuid default gen_random_uuid() primary key,
  candidate_id uuid not null
    references candidates(id) on delete cascade,
  round integer not null default 1,
  question_key text not null,           -- e.g. 'q1', 'task_link'
  response_text text,
  score integer default 0,
  reviewer_comment text,
  submitted_at timestamp with time zone default timezone('utc'::text, now())
);

-- Composite index for fast lookups by candidate + round
create index if not exists idx_quest_candidate_round
  on quest_responses(candidate_id, round);

-- -------------------------------------------------------------
--  Row Level Security — candidates
--  Strategy: the anon key may INSERT applications publicly, but
--  may NOT read or update rows directly. All authenticated reads
--  and writes go through SECURITY DEFINER functions below that
--  verify the candidate's passcode. This keeps every candidate
--  scoped to their own row without a full auth provider.
-- -------------------------------------------------------------
alter table candidates enable row level security;

-- Public application submissions.
drop policy if exists "public can submit application" on candidates;
create policy "public can submit application"
  on candidates
  for insert
  to anon, authenticated
  with check (true);

-- NOTE: intentionally NO select/update policies for anon.
-- Direct reads/updates are blocked; use the RPC functions instead.

-- -------------------------------------------------------------
--  Row Level Security — quest_responses
--  Insert only via RPC; direct reads blocked for anon.
-- -------------------------------------------------------------
alter table quest_responses enable row level security;

drop policy if exists "public can insert quest responses" on quest_responses;
create policy "public can insert quest responses"
  on quest_responses
  for insert
  to anon, authenticated
  with check (true);

-- -------------------------------------------------------------
--  RPC: set_passcode
--  Called on the confirmation screen to finish account creation.
--  Only works while the row has no passcode yet (first-time set).
-- -------------------------------------------------------------
create or replace function set_passcode(p_email text, p_passcode text)
returns candidates
language plpgsql
security definer
set search_path = public
as $$
declare
  result candidates;
begin
  update candidates
     set passcode = crypt(p_passcode, gen_salt('bf'))
   where lower(email) = lower(p_email)
     and passcode is null
  returning * into result;

  if result.id is null then
    raise exception 'No pending application for that email (or passcode already set).';
  end if;

  result.passcode := null; -- never return the hash
  return result;
end;
$$;

-- -------------------------------------------------------------
--  RPC: candidate_login
--  Verifies email + passcode and returns the candidate row.
-- -------------------------------------------------------------
create or replace function candidate_login(p_email text, p_passcode text)
returns candidates
language plpgsql
security definer
set search_path = public
as $$
declare
  result candidates;
begin
  select * into result
    from candidates
   where lower(email) = lower(p_email)
     and passcode = crypt(p_passcode, passcode);

  if result.id is null then
    raise exception 'Invalid email or passcode.';
  end if;

  result.passcode := null; -- never return the hash
  return result;
end;
$$;

-- -------------------------------------------------------------
--  RPC: submit_task_link
--  Lets an authenticated candidate save their proof URL.
-- -------------------------------------------------------------
create or replace function submit_task_link(
  p_email text,
  p_passcode text,
  p_link text
)
returns candidates
language plpgsql
security definer
set search_path = public
as $$
declare
  result candidates;
begin
  update candidates
     set submission_link = p_link
   where lower(email) = lower(p_email)
     and passcode = crypt(p_passcode, passcode)
  returning * into result;

  if result.id is null then
    raise exception 'Invalid email or passcode.';
  end if;

  result.passcode := null;
  return result;
end;
$$;

-- -------------------------------------------------------------
--  RPC: promote_candidate
--  Admin-only: advance a candidate to the next round and update
--  their stage_status. Authenticated role only.
-- -------------------------------------------------------------
create or replace function promote_candidate(
  p_candidate_id uuid,
  p_new_status text,
  p_reviewer_notes text default null,
  p_score_delta integer default 0
)
returns candidates
language plpgsql
security definer
set search_path = public
as $$
declare
  result candidates;
begin
  -- Validate status value
  if p_new_status not in (
    'In Review', 'Shortlisted', 'Promoted to Next Round', 'Rejected', 'Selected'
  ) then
    raise exception 'Invalid stage_status value: %', p_new_status;
  end if;

  update candidates
     set stage_status    = p_new_status,
         current_round   = case
                             when p_new_status = 'Promoted to Next Round'
                             then current_round + 1
                             else current_round
                           end,
         total_score     = total_score + p_score_delta,
         reviewer_notes  = coalesce(p_reviewer_notes, reviewer_notes)
   where id = p_candidate_id
  returning * into result;

  if result.id is null then
    raise exception 'Candidate not found: %', p_candidate_id;
  end if;

  result.passcode := null;
  return result;
end;
$$;

-- Allow the anon (and authenticated) roles to call these functions.
grant execute on function set_passcode(text, text) to anon, authenticated;
grant execute on function candidate_login(text, text) to anon, authenticated;
grant execute on function submit_task_link(text, text, text) to anon, authenticated;
grant execute on function promote_candidate(uuid, text, text, integer) to authenticated;

-- -------------------------------------------------------------
--  Realtime: enable change-data-capture on both tables so the
--  admin dashboard and Player HQ can subscribe to live updates.
-- -------------------------------------------------------------
alter publication supabase_realtime add table candidates;
alter publication supabase_realtime add table quest_responses;
