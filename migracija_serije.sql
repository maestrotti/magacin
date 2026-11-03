-- ISPRAVKA SERIJE (i količine/datuma) — pokreni kao rola "postgres" u Supabase → SQL Editor.
-- Pokreni POSLIJE svih ostalih migracija (najnovija je, ne mijenja postojeće podatke sama po sebi).
-- Sigurno je pokrenuti više puta (idempotentno). Ne briše transakcije, kontrole ni škart.
--
-- Šta dodaje:
--   * preimenuj_seriju(...)      — mijenja seriju na svim povezanim unosima za isti
--                                  magacin + proizvod (ulaz, izlaz, kontrole, škart).
--   * ispravi_unos_i_seriju(...) — ispravlja količinu, datum I seriju jednog unosa.
-- Stara funkcija ispravi_unos ostaje netaknuta (stariji ekrani nastavljaju raditi).
--
-- SIGURNOST PODATAKA: skripta NE briše tabele, kolone ni transakcije. Samo
-- kreira/zamjenjuje dvije funkcije i daje dozvolu za njihovo pokretanje.
-- Sve je u jednoj transakciji: ako bilo koji korak pukne, neće ostati pola primijenjeno.

begin;

-- ===== 1) Preimenovanje serije za magacin + proizvod =====
-- Serija je zajednička oznaka za sve unose istog proizvoda u magacinu, pa se mijenja
-- na svim povezanim zapisima kako kontrola/škart/izlaz ne bi ostali na staroj seriji.
create or replace function preimenuj_seriju(p_plant uuid, p_product uuid, p_serija_stara text, p_serija_nova text)
returns void language plpgsql security definer set search_path=public as $$
declare stara text := coalesce(p_serija_stara,''); nova text := trim(coalesce(p_serija_nova,''));
begin
  if not (is_upravnik() or is_admin() or can_plant(p_plant)) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if not exists(select 1 from plants where id=p_plant) then
    raise exception 'Nepoznat magacin';
  end if;
  if not exists(select 1 from products where id=p_product) then
    raise exception 'Nepoznat proizvod';
  end if;
  if stara = nova then return; end if;

  update movements
     set serija = nova
   where plant_id = p_plant and product_id = p_product and coalesce(serija,'') = stara;

  if to_regclass('public.kontrole') is not null then
    update kontrole
       set serija = nova
     where plant_id = p_plant and product_id = p_product and coalesce(serija,'') = stara;
  end if;

  -- Potvrda važi za tačnu seriju i tačnu količinu; poslije izmjene serije mora se ponovo potvrditi.
  if to_regclass('public.mok_potvrde') is not null then
    delete from mok_potvrde
     where plant_id = p_plant and product_id = p_product
       and coalesce(serija,'') in (stara, nova);
  end if;
end $$;

-- ===== 2) Ispravka unosa: količina + datum + serija =====
-- Ista pravila kao kod ispravi_unos (vođa samo svoje ulaze; upravnik/admin sve),
-- plus opciona ispravka serije. Ako se serija promijeni, preimenuje se na svim
-- povezanim unosima preko preimenuj_seriju().
create or replace function ispravi_unos_i_seriju(p_id uuid, p_qty int, p_date date, p_serija text)
returns void language plpgsql security definer set search_path=public as $$
declare r movements%rowtype; r2 movements%rowtype; st int; ns int; stara text; nova text;
begin
  select * into r from movements where id=p_id;
  if not found then raise exception 'Unos ne postoji'; end if;
  if not (is_upravnik() or is_admin() or can_plant(r.plant_id)) then
    raise exception 'Nemate pravo na ovaj unos';
  end if;
  if r.kind='skart' or r.kontrola_id is not null then
    raise exception 'Kontrola je završena. Prvo je obriši u Historiji → Kontrole, pa ispravi unos.';
  end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  if not (is_upravnik() or is_admin()) and r.kind<>'promet' then
    raise exception 'Vođa može ispravljati samo svoje ulaze';
  end if;
  if r.kind<>'promet' and r.transfer_id is null and not is_admin() then
    raise exception 'Staro prebacivanje bez veze s parom – ispravite ručno';
  end if;

  -- Serija se mijenja samo ako je polje poslano (null = ostavi kako jeste).
  if p_serija is not null then
    stara := coalesce(r.serija,'');
    nova := trim(p_serija);
    if nova <> stara then
      perform preimenuj_seriju(r.plant_id, r.product_id, stara, nova);
    end if;
  end if;

  -- Ne dozvoli ispravku koja bi dovela do negativnog stanja (npr. izlaz veći od ulaza).
  for r2 in select * from movements
             where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id)
  loop
    select coalesce(sum(qty_in-qty_out),0) into st from movements m
      where m.plant_id=r2.plant_id and m.product_id=r2.product_id and m.serija=r2.serija
        and m.status=r2.status
        and (exists(select 1 from plants p where p.id=r2.plant_id and not p.tracks_customer)
             or m.customer_id is not distinct from r2.customer_id);
    ns := case when r2.qty_in>0 then st-r2.qty_in+p_qty else st+r2.qty_out-p_qty end;
    if ns<0 then
      raise exception 'Ispravka bi dovela do negativnog stanja (bilo bi % kom)', ns;
    end if;
  end loop;

  update movements set
    qty_in=case when qty_in>0 then p_qty else 0 end,
    qty_out=case when qty_out>0 then p_qty else 0 end,
    date=coalesce(p_date,date),
    note=concat_ws(' · ',note,
      case when is_admin() then 'ispravio admin ' else 'ispravio korisnik ' end
      ||to_char(current_date,'DD.MM.YYYY')||', bilo '||greatest(r.qty_in,r.qty_out))
  where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id);
end $$;

-- ===== 3) Dozvole =====
grant execute on function preimenuj_seriju(uuid,uuid,text,text) to authenticated;
grant execute on function ispravi_unos_i_seriju(uuid,int,date,text) to authenticated;

-- ===== 4) Provjera prije potvrde transakcije =====
-- Ako SQL Editor nije pokrenut kao rola "postgres", funkcije se neće kreirati i
-- skripta ovdje jasno puca umjesto da tiho prijavi "Success".
do $$
begin
  if to_regprocedure('public.preimenuj_seriju(uuid,uuid,text,text)') is null
     or to_regprocedure('public.ispravi_unos_i_seriju(uuid,integer,date,text)') is null then
    raise exception 'Migracija nije uspjela: funkcije za seriju nisu kreirane. Provjeri da SQL Editor radi kao rola postgres.';
  end if;
end $$;

commit;

notify pgrst, 'reload schema';

-- ===== Provjere =====
select p.proname, pg_get_function_arguments(p.oid) as argumenti
from pg_proc p
where p.pronamespace='public'::regnamespace
  and p.proname in ('ispravi_unos','ispravi_unos_i_seriju','preimenuj_seriju')
order by p.proname;

select pl.name as magacin, pr.name as proizvod, m.serija, m.status,
       coalesce(sum(m.qty_in-m.qty_out),0) as stanje
from movements m
join plants pl on pl.id=m.plant_id
join products pr on pr.id=m.product_id
group by pl.name, pr.name, m.serija, m.status
order by pl.name, pr.name, m.serija
limit 30;
