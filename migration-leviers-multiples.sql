-- =====================================================================
--  PILOTE TV OUT : leviers multiples et obligatoires
--  Supabase → SQL Editor → New query → coller tout → Run
--  Ne modifie AUCUNE saisie existante. Peut être relancé sans risque.
-- =====================================================================

-- 1. Le champ « levier » accepte désormais plusieurs valeurs séparées par des virgules
--    (ex. « remise,option »). Les anciennes saisies (une seule valeur ou vide) restent valides.
do $$
declare c record;
begin
  for c in
    select con.conname
    from pg_constraint con
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = any(con.conkey)
    where con.conrelid = 'public.saisies'::regclass and con.contype = 'c' and att.attname = 'levier'
  loop
    execute format('alter table public.saisies drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.saisies add constraint saisies_levier_check check (
  levier ~ '^((remise|downgrade|option|tech|bundle|aucun)(,(remise|downgrade|option|tech|bundle|aucun))*)?$'
);

-- 2. Toute nouvelle saisie doit indiquer au moins un levier (« aucun » compte comme un choix).
create or replace function public.enregistrer_saisie(
  p_taa text, p_resultat text, p_motif text, p_levier text default '', p_remarque text default ''
) returns json
language plpgsql volatile security definer set search_path = public as $$
declare a public.agents; v_row public.saisies; v_lev text;
begin
  a := public._agent(p_taa);
  if a.taa is null then raise exception 'TAA inconnu ou désactivé' using errcode = '28000'; end if;
  -- nettoyage : minuscules, sans espaces, sans doublons, dans l'ordre standard
  select string_agg(x, ',' order by array_position(array['remise','downgrade','option','tech','bundle','aucun'], x))
    into v_lev
    from (select distinct trim(lower(x)) as x
          from unnest(string_to_array(coalesce(p_levier, ''), ',')) as x
          where trim(x) <> '') s;
  if v_lev is null then
    raise exception 'Levier obligatoire' using errcode = 'P0001';
  end if;
  insert into public.saisies (agent_taa, agent_nom, resultat, motif, levier, remarque)
  values (a.taa, public._nom_complet(a), p_resultat, p_motif, v_lev, left(coalesce(p_remarque, ''), 280))
  returning * into v_row;
  return json_build_object('id', v_row.id, 'created_at', v_row.created_at);
end $$;

grant execute on function public.enregistrer_saisie(text,text,text,text,text) to anon, authenticated;
