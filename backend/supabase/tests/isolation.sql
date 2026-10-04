-- Access rules of schema.sql, as the app meets them: members see and write their group, an outsider sees nothing.
-- Run after tests/stub.sql and schema.sql:  psql -v ON_ERROR_STOP=1 -f tests/isolation.sql   (exit code ≠ 0 on failure)
\set ON_ERROR_STOP on
\set fab '00000000-0000-0000-0000-00000000000a'
\set julien '00000000-0000-0000-0000-00000000000b'
\set intruder '00000000-0000-0000-0000-00000000000c'

insert into auth.users (id, raw_user_meta_data) values
  (:'fab', '{"display_name":"Fab"}'),
  (:'julien', '{"display_name":"Julien"}'),
  (:'intruder', '{"display_name":"Intrus"}');
select public.expect('profile created by the sign-up trigger', count(*), 3) from public.profiles;
select public.expect_text('pseudo comes from the sign-up data', display_name, 'Fab') from public.profiles where id = :'fab';

set role authenticated;

-- ── Groups and invitations ───────────────────────────────────────────────────────────────────────
set app.uid = :'fab';
create temp table g as select * from public.create_group('Alpes');
grant all on g to authenticated;
select public.expect('invite code has 8 characters', length(invite_code), 8) from g;
select public.expect_true('invite code avoids look-alike characters', invite_code ~ '^[A-HJKMNP-Z2-9]{8}$') from g;
select public.expect('creator is the first member', count(*), 1) from public.group_members;

set app.uid = :'julien';
select public.expect_text('joining with a sloppy code (lower case, dash)', name, 'Alpes')
  from public.join_group((select lower(substr(invite_code, 1, 4) || '-' || substr(invite_code, 5)) from g));
select public.expect('a member sees his co-members'' profiles', count(*), 2) from public.profiles;
select public.expect('roster lists both, creator flagged', count(*), 2) from public.group_roster((select id from g));
select public.expect_true('creator is flagged as owner', is_owner) from public.group_roster((select id from g)) where display_name = 'Fab';

-- ── Live position: upsert, own rows only, 5 minutes of visibility ───────────────────────────────
insert into public.positions (user_id, group_id, lat, lon, speed_kmh, course)
  select auth.uid(), id, 44.1, 6.2, 80, 90 from g;
set app.uid = :'fab';
insert into public.positions (user_id, group_id, lat, lon) select auth.uid(), id, 44.0, 6.0 from g;
select public.expect('both riders see both positions', count(*), 2) from public.positions;
update public.positions set lat = 44.05 where user_id = auth.uid();
update public.positions set lat = 0 where user_id = :'julien';
select public.expect('nobody moves someone else''s position', lat, 44.1) from public.positions where user_id = :'julien';

-- an upsert on a stale own row (dead zone) must still work, a friend must not see that stale row
reset role;
alter table public.positions disable trigger positions_touch;
update public.positions set updated_at = now() - interval '20 minutes' where user_id = :'fab';
alter table public.positions enable trigger positions_touch;
set role authenticated;
set app.uid = :'fab';
select public.expect('a rider always sees his own stale row', count(*), 2) from public.positions;
insert into public.positions (user_id, group_id, lat, lon) select auth.uid(), id, 44.5, 6.5 from g
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, group_id = excluded.group_id;
select public.expect_true('the upsert refreshed the stale row (server clock)', updated_at > now() - interval '1 minute')
  from public.positions where user_id = :'fab';
reset role;
alter table public.positions disable trigger positions_touch;
update public.positions set updated_at = now() - interval '20 minutes' where user_id = :'fab';
alter table public.positions enable trigger positions_touch;
set role authenticated;
set app.uid = :'julien';
select public.expect('a friend does not see a position older than 5 minutes', count(*), 1) from public.positions;

-- ── Chat ─────────────────────────────────────────────────────────────────────────────────────────
set app.uid = :'fab';
insert into public.messages (group_id, kind, body) select id, 'quick', 'J''arrive' from g;
do $$
begin
  begin
    insert into public.messages (group_id, user_id, kind, body)
      select id, '00000000-0000-0000-0000-00000000000b', 'text', 'faux' from g;
    raise exception 'FAIL impersonation allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.messages (group_id, kind, body) select id, 'text', repeat('x', 501) from g;
    raise exception 'FAIL 501-character message accepted';
  exception when check_violation then null;
  end;
end $$;
select public.expect('one message in the chat', count(*), 1) from public.messages;

-- ── Shared trips ─────────────────────────────────────────────────────────────────────────────────
insert into storage.objects (bucket_id, name) select 'trips', id || '/11111111-1111-1111-1111-111111111111.json' from g;
insert into public.shared_trips (id, group_id, name, days, distance_km, storage_path)
  select '11111111-1111-1111-1111-111111111111', id, 'Alpes 3 jours', 3, 650, id || '/11111111-1111-1111-1111-111111111111.json' from g;
set app.uid = :'julien';
select public.expect('a member reads the shared trip and its file', (select count(*) from public.shared_trips)
                                                                   + (select count(*) from storage.objects), 2);
delete from public.shared_trips;
select public.expect('only the author deletes a shared trip', count(*), 1) from public.shared_trips;
delete from storage.objects;
select public.expect('only the author deletes the trip file', count(*), 1) from storage.objects;

-- ── The outsider ─────────────────────────────────────────────────────────────────────────────────
set app.uid = :'intruder';
select public.expect('outsider sees no position', count(*), 0) from public.positions;
select public.expect('outsider sees no message', count(*), 0) from public.messages;
select public.expect('outsider sees no shared trip', count(*), 0) from public.shared_trips;
select public.expect('outsider sees no trip file', count(*), 0) from storage.objects;
select public.expect('outsider sees no group', count(*), 0) from public.groups;
select public.expect('outsider sees no member', count(*), 0) from public.group_members;
select public.expect('outsider sees only himself', count(*), 1) from public.profiles;
select public.expect('outsider gets an empty roster', count(*), 0) from public.group_roster((select id from g));
do $$
begin
  begin
    perform public.join_group('AAAAAAAA');
    raise exception 'FAIL wrong code accepted';
  exception when sqlstate 'P0002' then null;
  end;
  begin
    insert into public.positions (user_id, group_id, lat, lon)
      values (auth.uid(), '00000000-0000-0000-0000-000000000001', 1, 1);
    raise exception 'FAIL position inserted in a foreign group';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.rotate_invite((select id from g));
    raise exception 'FAIL outsider rotated the invitation';
  exception when sqlstate '42501' then null;
  end;
end $$;

-- ── Owner rights, size limit, leaving ────────────────────────────────────────────────────────────
set app.uid = :'julien';
do $$
begin
  begin
    perform public.rotate_invite((select id from g));
    raise exception 'FAIL a member rotated the invitation';
  exception when sqlstate '42501' then null;
  end;
end $$;
delete from public.group_members where user_id = :'fab';
select public.expect('a member cannot remove the owner', count(*), 2) from public.group_members;

set app.uid = :'fab';
select public.expect_true('the owner changes the code', invite_code <> (select invite_code from g))
  from public.rotate_invite((select id from g));

-- the group is full at 10 members
reset role;
insert into auth.users (id) select gen_random_uuid() from generate_series(1, 8);
insert into public.group_members (group_id, user_id)
  select (select id from g), id from auth.users where id not in (:'fab', :'julien', :'intruder');
select public.expect('group of 10', count(*), 10) from public.group_members;
select invite_code as code from public.groups where id = (select id from g) \gset
select set_config('app.code', :'code', false);
set role authenticated;
set app.uid = :'intruder';
do $$
begin
  begin
    perform public.join_group(current_setting('app.code'));
    raise exception 'FAIL an 11th member joined';
  exception when sqlstate 'P0003' then null;
  end;
end $$;
reset role;
select public.expect('the 11th member did not get in', count(*), 10) from public.group_members;

-- Julien leaves: his position goes with him
set role authenticated;
set app.uid = :'julien';
select public.leave_group((select id from g));
reset role;
select public.expect('leaving deletes the position', count(*), 0) from public.positions where user_id = :'julien';

-- ownership passes to the oldest member when the owner leaves
set role authenticated;
set app.uid = :'fab';
select public.leave_group((select id from g));
reset role;
select public.expect_true('ownership passed to someone still in the group',
  (select owner_id from public.groups where id = (select id from g)) in (select user_id from public.group_members));

-- ── Deleting an account removes everything of that person ───────────────────────────────────────
set role authenticated;
set app.uid = :'intruder';
select public.delete_account();
reset role;
select public.expect('account deleted', count(*), 0) from auth.users where id = :'intruder';
select public.expect('profile deleted with it', count(*), 0) from public.profiles where id = :'intruder';
