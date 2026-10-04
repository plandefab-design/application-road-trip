-- Moto Road — groupe d'amis (SPEC §13, M10).
-- À coller en entier dans Supabase › SQL Editor › Run. Peut être relancé sans danger (idempotent).
-- Aucune donnée personnelle dans ce fichier : seulement la structure et les règles d'accès (RLS).

-- ───────────────────────── Tables ─────────────────────────

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 20),
  created_at timestamptz not null default now()
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  invite_code text not null unique,
  owner_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user_idx on public.group_members (user_id);

-- Une seule position par motard (remplacée toutes les 4 s en roulant). Invisible après 5 minutes.
create table if not exists public.positions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  group_id uuid not null references public.groups (id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  speed_kmh real,
  course real,
  updated_at timestamptz not null default now()
);
create index if not exists positions_group_idx on public.positions (group_id);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('text', 'quick', 'trip')),
  body text not null check (char_length(body) between 1 and 500),
  share_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists messages_group_idx on public.messages (group_id, id desc);

-- Trips partagés : la ligne décrit le trip, le fichier trip.json est dans le stockage (bucket « trips »).
create table if not exists public.shared_trips (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  days integer not null default 0,
  distance_km real not null default 0,
  storage_path text not null,
  created_at timestamptz not null default now()
);
create index if not exists shared_trips_group_idx on public.shared_trips (group_id, created_at desc);

-- ───────────────────────── Fonctions ─────────────────────────

-- Le serveur date les positions : l'heure du téléphone n'entre pas en jeu.
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists positions_touch on public.positions;
create trigger positions_touch before insert or update on public.positions
  for each row execute function public.touch_updated_at();

create or replace function public.is_group_member(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid());
$$;

create or replace function public.shares_group_with(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select uid = auth.uid() or exists (
    select 1 from public.group_members a
    join public.group_members b on a.group_id = b.group_id
    where a.user_id = auth.uid() and b.user_id = uid);
$$;

-- Le profil est créé à l'inscription, avec le pseudo donné par l'app.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text;
begin
  name := left(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 20);
  if char_length(name) < 2 then name := 'Motard'; end if;
  insert into public.profiles (id, display_name) values (new.id, name) on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Code d'invitation de 8 caractères, sans 0/O/1/I/L (lisible au téléphone).
create or replace function public.random_invite_code() returns text
language plpgsql volatile as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text := '';
begin
  for i in 1..8 loop
    code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return code;
end $$;

create or replace function public.create_group(group_name text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  tries int := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  loop
    begin
      insert into public.groups (name, invite_code, owner_id)
      values (left(trim(group_name), 40), public.random_invite_code(), auth.uid())
      returning * into g;
      exit;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;
  insert into public.group_members (group_id, user_id) values (g.id, auth.uid());
  return g;
end $$;

-- 10 membres au plus : bien assez pour une bande d'amis, et ça borne le trafic du forfait gratuit.
create or replace function public.join_group(code text) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select * into g from public.groups
    where invite_code = upper(regexp_replace(code, '[\s-]', '', 'g'));
  if not found then raise exception 'invalid code' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.group_members where group_id = g.id and user_id = auth.uid())
     and (select count(*) from public.group_members where group_id = g.id) >= 10 then
    raise exception 'group full' using errcode = 'P0003';
  end if;
  insert into public.group_members (group_id, user_id) values (g.id, auth.uid()) on conflict do nothing;
  return g;
end $$;

-- Le propriétaire change le code (l'ancien lien d'invitation cesse de marcher).
create or replace function public.rotate_invite(gid uuid) returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  update public.groups set invite_code = public.random_invite_code()
    where id = gid and owner_id = auth.uid() returning * into g;
  if not found then raise exception 'not the owner' using errcode = '42501'; end if;
  return g;
end $$;

-- Quitter : la position partagée disparaît ; si le propriétaire part, le plus ancien membre prend la suite
-- (et le groupe est supprimé s'il ne reste personne).
create or replace function public.leave_group(gid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare next_owner uuid;
begin
  delete from public.positions where user_id = auth.uid() and group_id = gid;
  delete from public.group_members where group_id = gid and user_id = auth.uid();
  if exists (select 1 from public.groups where id = gid and owner_id = auth.uid()) then
    select user_id into next_owner from public.group_members where group_id = gid order by joined_at limit 1;
    if next_owner is null then
      delete from public.groups where id = gid;
    else
      update public.groups set owner_id = next_owner where id = gid;
    end if;
  end if;
end $$;

-- Les membres d'un groupe avec leur pseudo, en un seul appel (réservé aux membres).
create or replace function public.group_roster(gid uuid)
returns table (user_id uuid, display_name text, is_owner boolean)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.display_name, g.owner_id = m.user_id
  from public.group_members m
  join public.groups g on g.id = m.group_id
  join public.profiles p on p.id = m.user_id
  where m.group_id = gid and public.is_group_member(gid)
  order by m.joined_at;
$$;

-- Suppression du compte : profil, appartenances, positions, messages et trips partagés partent avec lui.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke all on function public.create_group(text), public.join_group(text), public.rotate_invite(uuid),
  public.leave_group(uuid), public.group_roster(uuid), public.delete_account() from public, anon;
grant execute on function public.create_group(text), public.join_group(text), public.rotate_invite(uuid),
  public.leave_group(uuid), public.group_roster(uuid), public.delete_account() to authenticated;

-- ───────────────────────── Règles d'accès (RLS) ─────────────────────────

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.positions enable row level security;
alter table public.messages enable row level security;
alter table public.shared_trips enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (public.shares_group_with(id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists groups_select on public.groups;
create policy groups_select on public.groups for select to authenticated
  using (public.is_group_member(id));
drop policy if exists groups_delete on public.groups;
create policy groups_delete on public.groups for delete to authenticated
  using (owner_id = auth.uid());

drop policy if exists members_select on public.group_members;
create policy members_select on public.group_members for select to authenticated
  using (public.is_group_member(group_id));
-- Chacun peut partir ; le propriétaire peut retirer quelqu'un.
drop policy if exists members_delete on public.group_members;
create policy members_delete on public.group_members for delete to authenticated
  using (user_id = auth.uid()
         or exists (select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid()));

drop policy if exists positions_select on public.positions;
-- Sa propre ligne reste toujours visible de son auteur : un « upsert » relit la ligne existante, même vieille
-- (après une zone sans réseau), sinon la mise à jour serait refusée.
create policy positions_select on public.positions for select to authenticated
  using (public.is_group_member(group_id)
         and (user_id = auth.uid() or updated_at > now() - interval '5 minutes'));
drop policy if exists positions_insert on public.positions;
create policy positions_insert on public.positions for insert to authenticated
  with check (user_id = auth.uid() and public.is_group_member(group_id));
drop policy if exists positions_update on public.positions;
create policy positions_update on public.positions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_group_member(group_id));
drop policy if exists positions_delete on public.positions;
create policy positions_delete on public.positions for delete to authenticated
  using (user_id = auth.uid());

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.is_group_member(group_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (user_id = auth.uid() and public.is_group_member(group_id));

drop policy if exists shared_trips_select on public.shared_trips;
create policy shared_trips_select on public.shared_trips for select to authenticated
  using (public.is_group_member(group_id));
drop policy if exists shared_trips_insert on public.shared_trips;
create policy shared_trips_insert on public.shared_trips for insert to authenticated
  with check (user_id = auth.uid() and public.is_group_member(group_id));
drop policy if exists shared_trips_delete on public.shared_trips;
create policy shared_trips_delete on public.shared_trips for delete to authenticated
  using (user_id = auth.uid());

-- ───────────────────────── Stockage des trips (fichiers privés) ─────────────────────────

insert into storage.buckets (id, name, public, file_size_limit)
values ('trips', 'trips', false, 20971520)
on conflict (id) do nothing;

-- Chemin d'un fichier : <id du groupe>/<id du partage>.json
drop policy if exists trips_files_select on storage.objects;
create policy trips_files_select on storage.objects for select to authenticated
  using (bucket_id = 'trips' and public.is_group_member(((storage.foldername(name))[1])::uuid));
drop policy if exists trips_files_insert on storage.objects;
create policy trips_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trips' and public.is_group_member(((storage.foldername(name))[1])::uuid));
drop policy if exists trips_files_delete on storage.objects;
create policy trips_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'trips' and exists (
    select 1 from public.shared_trips s where s.storage_path = name and s.user_id = auth.uid()));

-- ───────────────────────── Nettoyage automatique (facultatif) ─────────────────────────
-- Positions oubliées après une panne de réseau : effacées après 1 h. Messages : 90 jours.
-- Demande l'extension pg_cron ; si elle n'est pas disponible, le reste du script reste valide.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('moto-road-purge-positions', '*/15 * * * *',
    $job$ delete from public.positions where updated_at < now() - interval '1 hour' $job$);
  perform cron.schedule('moto-road-purge-messages', '17 3 * * *',
    $job$ delete from public.messages where created_at < now() - interval '90 days' $job$);
exception when others then
  raise notice 'pg_cron indisponible (%), nettoyage automatique non activé', sqlerrm;
end $$;
