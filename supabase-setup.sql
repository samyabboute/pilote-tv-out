-- =====================================================================
--  PILOTE TV OUT : installation de la base
--  Supabase → SQL Editor → New query → coller tout → Run
--  Connexion de tout le monde par TAA. Les rôles : agent ou admin.
--  Peut être relancé sans risque (ne supprime aucune saisie).
-- =====================================================================

create extension if not exists pgcrypto;

-- Nettoyage d'une éventuelle version précédente (connexion par e-mail)
drop function if exists public.compte_par_agent();
drop function if exists public.is_admin() cascade;
drop table if exists public.admins cascade;

-- ---------- Tables ----------
create table if not exists public.agents (
  taa        text primary key check (taa ~ '^[A-Z0-9]{4,20}$'),
  prenom     text not null default '' check (char_length(prenom) <= 60),
  nom        text not null check (char_length(nom) between 1 and 80),
  actif      boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.agents add column if not exists role text not null default 'agent';
alter table public.agents add column if not exists prenom text not null default '';
do $$ begin
  alter table public.agents add constraint agents_role_chk check (role in ('agent','admin'));
exception when duplicate_object then null; end $$;

create table if not exists public.saisies (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  agent_taa  text references public.agents(taa) on update cascade on delete set null,
  agent_nom  text not null,
  resultat   text not null check (resultat in ('retenu','resilie')),
  motif      text not null check (motif in ('prix','streaming','concurrence','usage','technique','contenu','demenagement','menage','autre')),
  levier     text not null default '' check (levier in ('','remise','downgrade','option','tech','bundle','aucun')),
  remarque   text not null default '' check (char_length(remarque) <= 280)
);
create index if not exists saisies_created_at_idx on public.saisies (created_at desc);
create index if not exists saisies_agent_idx on public.saisies (agent_taa);

create table if not exists public.tentatives (
  ip text not null,
  at timestamptz not null default now()
);
create index if not exists tentatives_idx on public.tentatives (ip, at);

-- Aucun accès direct aux tables depuis Internet : tout passe par les fonctions.
alter table public.agents     enable row level security;
alter table public.saisies    enable row level security;
alter table public.tentatives enable row level security;
drop policy if exists agents_admin on public.agents;
drop policy if exists saisies_admin_lecture on public.saisies;
drop policy if exists saisies_admin_modif on public.saisies;
drop policy if exists saisies_admin_suppr on public.saisies;

-- ---------- Outils internes ----------
create or replace function public._ip() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip',
    trim(split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1)),
    'inconnu');
$$;

create or replace function public._agent(p_taa text) returns public.agents
language sql stable security definer set search_path = public as $$
  select * from public.agents where taa = upper(regexp_replace(coalesce(p_taa,''), '\s', '', 'g')) and actif;
$$;

create or replace function public._nom_complet(a public.agents) returns text
language sql immutable as $$ select trim(coalesce(a.prenom,'') || ' ' || coalesce(a.nom,'')) $$;

create or replace function public._exiger_admin(p_taa text) returns public.agents
language plpgsql stable security definer set search_path = public as $$
declare a public.agents;
begin
  a := public._agent(p_taa);
  if a.taa is null or a.role <> 'admin' then
    raise exception 'Accès réservé aux admins' using errcode = '42501';
  end if;
  return a;
end $$;

-- ---------- Connexion (tout le monde) ----------
create or replace function public.connexion(p_taa text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare a public.agents; v_ip text := public._ip();
begin
  delete from public.tentatives where at < now() - interval '1 day';
  -- 30 erreurs de TAA en 15 minutes depuis la même adresse = blocage temporaire
  if v_ip <> 'inconnu' and (select count(*) from public.tentatives where ip = v_ip and at > now() - interval '15 minutes') >= 30 then
    raise exception 'Trop d''essais' using errcode = '54000';
  end if;
  a := public._agent(p_taa);
  if a.taa is null then
    insert into public.tentatives (ip) values (v_ip);
    return null;
  end if;
  return json_build_object('taa', a.taa, 'nom', public._nom_complet(a), 'prenom', a.prenom, 'role', a.role);
end $$;

-- ---------- Agents : saisie ----------
create or replace function public.enregistrer_saisie(
  p_taa text, p_resultat text, p_motif text, p_levier text default '', p_remarque text default ''
) returns json
language plpgsql volatile security definer set search_path = public as $$
declare a public.agents; v_row public.saisies;
begin
  a := public._agent(p_taa);
  if a.taa is null then raise exception 'TAA inconnu ou désactivé' using errcode = '28000'; end if;
  insert into public.saisies (agent_taa, agent_nom, resultat, motif, levier, remarque)
  values (a.taa, public._nom_complet(a), p_resultat, p_motif, coalesce(p_levier, ''), left(coalesce(p_remarque, ''), 280))
  returning * into v_row;
  return json_build_object('id', v_row.id, 'created_at', v_row.created_at);
end $$;

create or replace function public.resume_agent(p_taa text) returns json
language plpgsql stable security definer set search_path = public as $$
declare a public.agents;
        v_debut timestamptz := date_trunc('day', now() at time zone 'Europe/Zurich') at time zone 'Europe/Zurich';
begin
  a := public._agent(p_taa);
  if a.taa is null then return null; end if;
  return json_build_object(
    'nom', public._nom_complet(a), 'role', a.role,
    'equipe_total',   (select count(*) from public.saisies where created_at >= v_debut),
    'equipe_retenus', (select count(*) from public.saisies where created_at >= v_debut and resultat = 'retenu'),
    'moi_total',      (select count(*) from public.saisies where created_at >= v_debut and agent_taa = a.taa),
    'dernieres', coalesce((select json_agg(x) from (
        select id, created_at, resultat, motif from public.saisies
        where agent_taa = a.taa order by created_at desc limit 6) x), '[]'::json)
  );
end $$;

create or replace function public.annuler_saisie(p_taa text, p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare a public.agents;
begin
  a := public._agent(p_taa);
  if a.taa is null then return false; end if;
  delete from public.saisies where id = p_id and agent_taa = a.taa and created_at > now() - interval '10 minutes';
  return found;
end $$;

-- ---------- Admins : tableau de bord ----------
create or replace function public.admin_saisies(p_taa text, p_depuis timestamptz default null) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exiger_admin(p_taa);
  return coalesce((select json_agg(s order by s.created_at desc) from public.saisies s
                   where p_depuis is null or s.created_at >= p_depuis), '[]'::json);
end $$;

create or replace function public.admin_supprimer_saisie(p_taa text, p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._exiger_admin(p_taa);
  delete from public.saisies where id = p_id;
  return found;
end $$;

-- ---------- Admins : gestion des utilisateurs ----------
create or replace function public.admin_agents(p_taa text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._exiger_admin(p_taa);
  return coalesce((select json_agg(x order by x.nom_complet) from (
    select a.taa, a.prenom, a.nom, public._nom_complet(a) as nom_complet, a.role, a.actif, a.created_at,
           (select count(*) from public.saisies s where s.agent_taa = a.taa) as total,
           (select max(created_at) from public.saisies s where s.agent_taa = a.taa) as derniere
    from public.agents a) x), '[]'::json);
end $$;

create or replace function public._verifier_admins_restants() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.agents where role = 'admin' and actif) then
    raise exception 'Il doit rester au moins un admin actif' using errcode = 'P0001';
  end if;
end $$;

drop function if exists public.admin_enregistrer_agent(text,text,text,text,text,boolean);
create or replace function public.admin_enregistrer_agent(
  p_taa text, p_ancien_taa text, p_nouveau_taa text, p_prenom text, p_nom text, p_role text, p_actif boolean
) returns json
language plpgsql volatile security definer set search_path = public as $$
declare v_new text := upper(regexp_replace(coalesce(p_nouveau_taa,''), '\s', '', 'g'));
        v_old text := upper(regexp_replace(coalesce(p_ancien_taa,''), '\s', '', 'g'));
        v_prenom text := regexp_replace(trim(coalesce(p_prenom,'')), '\s+', ' ', 'g');
        v_nom text := regexp_replace(trim(coalesce(p_nom,'')), '\s+', ' ', 'g');
begin
  perform public._exiger_admin(p_taa);
  if v_new !~ '^[A-Z0-9]{4,20}$' then raise exception 'TAA invalide : 4 à 20 lettres ou chiffres' using errcode = 'P0001'; end if;
  if v_prenom = '' or v_nom = '' then raise exception 'Prénom et nom obligatoires' using errcode = 'P0001'; end if;
  if v_old = '' then
    insert into public.agents (taa, prenom, nom, role, actif) values (v_new, v_prenom, v_nom, coalesce(p_role,'agent'), coalesce(p_actif,true));
  else
    update public.agents set taa = v_new, prenom = v_prenom, nom = v_nom, role = coalesce(p_role, role),
           actif = coalesce(p_actif, actif), updated_at = now()
    where taa = v_old;
    if not found then raise exception 'Utilisateur introuvable' using errcode = 'P0002'; end if;
  end if;
  perform public._verifier_admins_restants();
  return json_build_object('taa', v_new);
end $$;

create or replace function public.admin_supprimer_agent(p_taa text, p_cible text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare me public.agents; v_ok boolean;
begin
  me := public._exiger_admin(p_taa);
  if upper(p_cible) = me.taa then raise exception 'Vous ne pouvez pas supprimer votre propre compte' using errcode = 'P0001'; end if;
  delete from public.agents where taa = upper(p_cible);
  v_ok := found;
  perform public._verifier_admins_restants();
  return v_ok;
end $$;

create or replace function public.admin_importer(p_taa text, p_lignes json) returns integer
language plpgsql volatile security definer set search_path = public as $$
declare r json; n integer := 0;
begin
  perform public._exiger_admin(p_taa);
  for r in select * from json_array_elements(p_lignes) loop
    if coalesce(trim(r->>'prenom'),'') = '' or coalesce(trim(r->>'nom'),'') = '' then continue; end if;
    insert into public.agents (taa, prenom, nom, role)
    values (upper(r->>'taa'), trim(r->>'prenom'), trim(r->>'nom'), case when r->>'role' = 'admin' then 'admin' else 'agent' end)
    on conflict (taa) do update set prenom = excluded.prenom, nom = excluded.nom, role = excluded.role, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Droits d'exécution ----------
revoke all on function public._ip(), public._agent(text), public._nom_complet(public.agents), public._exiger_admin(text), public._verifier_admins_restants() from public, anon, authenticated;
revoke all on all tables in schema public from anon, authenticated;
grant execute on function
  public.connexion(text),
  public.enregistrer_saisie(text,text,text,text,text),
  public.resume_agent(text),
  public.annuler_saisie(text,uuid),
  public.admin_saisies(text,timestamptz),
  public.admin_supprimer_saisie(text,uuid),
  public.admin_agents(text),
  public.admin_enregistrer_agent(text,text,text,text,text,text,boolean),
  public.admin_supprimer_agent(text,text),
  public.admin_importer(text,json)
to anon, authenticated;

-- ---------- Équipe du pilote : agents ----------
insert into public.agents (taa, prenom, nom, role) values
  ('TAACIAB1', 'Aboubacar Sidiki', 'Cissoko',     'agent'),
  ('TAALUALF', 'Albi',             'Lubila',      'agent'),
  ('TAAAWCA1', 'Cantelle Opportune','Awoyodo',    'agent'),
  ('TAAMFFR1', 'Diack Franche',    'Mfoukamanou', 'agent'),
  ('TAANDDO1', 'Don Fleury',       'Nduwingoma',  'agent'),
  ('TAAZEFA4', 'Fares',            'Zerrouki',    'agent'),
  ('TAANTJE4', 'Jeremie Muza',     'Ntiaka',      'agent'),
  ('TAAMASY2', 'Mamadou Mounir',   'Sylla',       'agent'),
  ('TAASAIN2', 'Ines',             'Saadane',     'agent'),
  ('TAADASAF', 'Sami',             'Dahmouni',    'agent'),
  ('TAADETH7', 'Théo',             'Destro',      'agent'),
  ('TAAMEYA8', 'Yazid',            'Mehdaoui',    'agent'),
  ('TAABEZA3', 'Zakaria',          'Bendjema',    'agent'),
  ('TAAMAZA1', 'Zaki',             'Mansouri',    'agent')
on conflict (taa) do update set prenom = excluded.prenom, nom = excluded.nom
  where public.agents.prenom = '';

-- ---------- Équipe du pilote : admins (accès complet) ----------
insert into public.agents (taa, prenom, nom, role) values
  ('TAAABSAA', 'Samy',       'Abboute',  'admin'),
  ('TAAKUJU8', 'Justyna',    'Kunz',     'admin'),
  ('TAAKEOU1', 'Oumar',      'Keita',    'admin'),
  ('TAAWYBA3', 'Bartlomiej', 'Wyżycki',  'admin'),
  ('TAAMIMIR', 'Missoum',    'Milagh',   'admin'),
  ('TAABEMOG', 'Mohammed',   'Bessalah', 'admin'),
  ('TAAHAMED', 'Mehdi',      'Hassiani', 'admin'),
  ('TAABEAM8', 'Amar',       'Berdous',  'admin'),
  ('TAASAVE2', 'Veli',       'Sarikaya', 'admin'),
  ('TAAENAL3', 'Alain',      'Enombong', 'admin'),
  ('TAAMEMO0', 'Mohamed',    'Medjras',  'admin')
on conflict (taa) do update set role = 'admin',
  prenom = case when public.agents.prenom = '' then excluded.prenom else public.agents.prenom end,
  nom    = case when public.agents.prenom = '' then excluded.nom    else public.agents.nom end;
