-- Objekti (pogoni/magacini): kreiranje ulaznog + izlaznog magacina i dodjela korisnika
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor, POSLIJE migracija_mok_dnevna_kontrola.sql.
-- Sigurno je pokrenuti više puta (idempotentno). Ne briše postojeće transakcije.
--
-- Model:
--   * Objekat = ulazni magacin (plants.is_store = true). Tu ostaje stanje.
--   * Izlazni magacin = plants.is_store = false, vezan preko plants.dest_for i
--     plants.output_plant_id. Šta izađe vidi se samo u Historiji.
--   * Način rada:
--       mok      -> tracks_customer = false (proizvodnja + kontrola, PP/GP)
--       magacin  -> tracks_customer = true  (klasičan ulaz/izlaz po kupcu)
--   * Svaki objekat ima svoje kupce i nazive proizvoda (customers.plant_id / products.plant_id).

-- ===== 1) Veza ulazni -> izlazni magacin =====
alter table plants add column if not exists output_plant_id uuid references plants(id) on delete set null;

-- Postojeći MOK: ako Laboracija postoji, veži je kao izlazni magacin.
update plants set output_plant_id=(select id from plants where lower(name)='laboracija' limit 1)
 where lower(name)='pogon mok' and output_plant_id is null
   and exists(select 1 from plants where lower(name)='laboracija');

-- ===== 2) Kreiranje objekta (ulazni + izlazni magacin) =====
create or replace function admin_napravi_objekat(p_name text, p_mode text, p_out text)
returns uuid language plpgsql security definer set search_path=public as $$
declare n text := trim(coalesce(p_name,'')); o text := trim(coalesce(p_out,''));
        iid uuid; oid uuid;
begin
  if not is_admin() then raise exception 'Samo admin može kreirati objekat'; end if;
  if length(n) < 2 then raise exception 'Upiši naziv objekta / ulaznog magacina'; end if;
  if length(o) < 2 then raise exception 'Upiši naziv izlaznog magacina'; end if;
  if lower(n) = lower(o) then raise exception 'Ulazni i izlazni magacin ne mogu imati isti naziv'; end if;
  if p_mode not in ('mok','magacin') then raise exception 'Način rada mora biti mok ili magacin'; end if;
  if exists(select 1 from plants where lower(name)=lower(n)) then
    raise exception 'Već postoji magacin/pogon "%"', n;
  end if;
  if exists(select 1 from plants where lower(name)=lower(o)) then
    raise exception 'Već postoji magacin/pogon "%"', o;
  end if;

  insert into plants(name,is_store,is_main,tracks_customer)
  values(n,true,false,(p_mode='magacin')) returning id into iid;

  insert into plants(name,is_store,is_main,tracks_customer,dest_for)
  values(o,false,false,true,iid) returning id into oid;

  update plants set output_plant_id=oid where id=iid;
  return iid;
end $$;

-- ===== 3) Dodjela korisnika objektu =====
-- Jedan vođa = jedan objekat. Upravnik/admin ne moraju imati dodjelu (vide sve).
create or replace function admin_postavi_plant(p_user uuid, p_plant uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Samo admin može dodjeljivati objekat'; end if;
  if not exists(select 1 from profiles where id=p_user) then raise exception 'Korisnik ne postoji'; end if;
  if p_plant is not null and not exists(select 1 from plants where id=p_plant and is_store) then
    raise exception 'Objekat ne postoji ili nije ulazni magacin';
  end if;
  delete from user_plants where user_id=p_user;
  if p_plant is not null then
    insert into user_plants(user_id,plant_id) values(p_user,p_plant) on conflict do nothing;
  end if;
  update profiles set plant_id=p_plant where id=p_user;
end $$;

grant execute on function admin_napravi_objekat(text,text,text) to authenticated;
grant execute on function admin_postavi_plant(uuid,uuid) to authenticated;

notify pgrst, 'reload schema';

-- ===== Provjere =====
select 'plants.output_plant_id' as provjera, count(*) as ima
from information_schema.columns
where table_schema='public' and table_name='plants' and column_name='output_plant_id';

select 'funkcije' as provjera, count(*) as ima
from pg_proc
where proname in ('admin_napravi_objekat','admin_postavi_plant')
  and pronamespace='public'::regnamespace;

select p.name as magacin,
  case when p.is_main then 'glavni'
       when not p.is_store then 'izlazni'
       when p.tracks_customer then 'magacin'
       else 'mok' end as vrsta,
  o.name as izlazni_magacin
from plants p left join plants o on o.id=p.output_plant_id
order by p.is_store desc, p.name;


-- ===== 4) Brisanje objekta (ulazni + izlazni magacin + svi povezani podaci) =====
create or replace function admin_obrisi_objekat(p_plant uuid)
returns void language plpgsql security definer set search_path=public as $$
declare oid uuid;
begin
  if not is_admin() then raise exception 'Samo admin može brisati objekat'; end if;
  if not exists(select 1 from plants where id=p_plant and is_store and not is_main) then
    raise exception 'Objekat ne postoji ili je glavni magacin';
  end if;
  if lower((select name from plants where id=p_plant)) = 'pogon mok' then
    raise exception 'Pogon MOK se ne može obrisati';
  end if;
  select output_plant_id into oid from plants where id=p_plant;
  delete from user_plants where plant_id=p_plant or plant_id=oid;
  update profiles set plant_id=null where plant_id=p_plant or plant_id=oid;
  delete from movements where plant_id=p_plant or plant_id=oid or to_plant=p_plant or to_plant=oid;
  delete from kontrole where plant_id=p_plant;
  delete from mok_potvrde where plant_id=p_plant;
  delete from stock_customers where plant_id=p_plant;
  delete from customers where plant_id=p_plant;
  delete from products where plant_id=p_plant;
  if oid is not null then delete from plants where id=oid; end if;
  delete from plants where id=p_plant;
end $$;

grant execute on function admin_obrisi_objekat(uuid) to authenticated;

notify pgrst, 'reload schema';
