-- admin_objekti.sql
-- Funkcije za Admin -> Pogoni: "+ Objekat" i brisanje objekta.
-- Pokreni u Supabase SQL Editoru (rola postgres). Idempotentno je, može se pokrenuti više puta.
-- Ne sadrži lozinke, pa smije na GitHub.

-- 1) Kolone koje aplikacija koristi na tabeli plants
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='plants' and column_name='tracks_customer') then
    alter table public.plants add column tracks_customer boolean not null default true;
    -- postojeći Pogon MOK ostaje MOK (aplikacija ga prepoznaje po tracks_customer = false)
    update public.plants set tracks_customer = false where name ~* 'pogon\s*mok';
  end if;
end $$;

alter table public.plants add column if not exists output_plant_id uuid;
alter table public.plants add column if not exists dest_for uuid;

drop function if exists public.admin_napravi_objekat(text, text, text);
drop function if exists public.admin_obrisi_objekat(uuid);

-- 2) Novi objekat = ulazni magacin + njegov izlazni magacin
create or replace function public.admin_napravi_objekat(p_name text, p_mode text, p_out text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_store uuid;
  v_out   uuid;
  n text := btrim(coalesce(p_name, ''));
  o text := btrim(coalesce(p_out, ''));
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Samo admin može praviti objekte';
  end if;
  if n = '' then raise exception 'Upiši naziv ulaznog magacina'; end if;
  if o = '' then raise exception 'Upiši naziv izlaznog magacina'; end if;
  if lower(n) = lower(o) then raise exception 'Ulazni i izlazni magacin moraju imati različite nazive'; end if;
  if p_mode not in ('magacin', 'mok') then raise exception 'Nepoznat način rada: %', p_mode; end if;
  if exists (select 1 from public.plants where lower(name) = lower(n)) then
    raise exception 'Objekat s nazivom "%" već postoji', n;
  end if;

  insert into public.plants (name, is_store, is_main, tracks_customer)
  values (n, true, false, p_mode <> 'mok')
  returning id into v_store;

  insert into public.plants (name, is_store, is_main, dest_for)
  values (o, false, false, v_store)
  returning id into v_out;

  update public.plants set output_plant_id = v_out where id = v_store;

  return v_store;
end $$;

-- 3) Brisanje objekta (ulaz + izlaz + svi zavisni podaci)
create or replace function public.admin_obrisi_objekat(p_plant uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pl      public.plants%rowtype;
  st      public.plants%rowtype;
  v_store uuid;
  v_out   uuid;
  ids     uuid[];
  r       record;
  passno  int;
  failed  boolean;
  last_err text;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Samo admin može brisati objekte';
  end if;

  select * into pl from public.plants where id = p_plant;
  if not found then raise exception 'Objekat ne postoji'; end if;

  if pl.output_plant_id is not null then
    v_store := pl.id;  v_out := pl.output_plant_id;
  elsif pl.dest_for is not null then
    v_store := pl.dest_for;  v_out := pl.id;
  else
    raise exception 'Odabrani zapis nije objekat (nema par ulaz/izlaz)';
  end if;

  select * into st from public.plants where id = v_store;
  if not found then raise exception 'Ulazni magacin objekta ne postoji'; end if;
  if st.is_main or st.name ~* '^pogon\s*mok$' then
    raise exception 'Glavni magacin i Pogon MOK se ne mogu obrisati';
  end if;

  ids := array[v_store, v_out];

  -- raskini međusobne veze
  update public.plants set output_plant_id = null where output_plant_id = any(ids);
  update public.plants set dest_for = null where dest_for = any(ids);
  update public.profiles set plant_id = null where plant_id = any(ids);

  -- obriši zavisne zapise iz svih tabela koje imaju kolonu plant_id / to_plant / from_plant.
  -- Redoslijed zavisnosti (strani ključevi) se rješava ponavljanjem prolaza.
  for passno in 1..8 loop
    failed := false;
    for r in
      select c.table_name, c.column_name
      from information_schema.columns c
      join information_schema.tables t
        on t.table_schema = c.table_schema and t.table_name = c.table_name
      where c.table_schema = 'public'
        and t.table_type = 'BASE TABLE'
        and c.column_name in ('plant_id', 'to_plant', 'from_plant')
        and c.table_name not in ('plants', 'profiles')
    loop
      begin
        execute format('delete from public.%I where %I = any($1)', r.table_name, r.column_name) using ids;
      exception when foreign_key_violation then
        failed := true;
        get stacked diagnostics last_err = message_text;
      end;
    end loop;
    exit when not failed;
  end loop;

  if failed then
    raise exception 'Ne mogu obrisati zavisne zapise: %', last_err;
  end if;

  delete from public.plants where id = any(ids);
end $$;

revoke all on function public.admin_napravi_objekat(text, text, text) from public, anon;
revoke all on function public.admin_obrisi_objekat(uuid) from public, anon;
grant execute on function public.admin_napravi_objekat(text, text, text) to authenticated;
grant execute on function public.admin_obrisi_objekat(uuid) to authenticated;

notify pgrst, 'reload schema';
