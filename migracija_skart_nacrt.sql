-- MOK: škart se može sačuvati prije potvrde kontrole (nacrt), pa kontrola kasnije
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor, POSLIJE migracija_razdvajanje.sql.
-- Sigurno je pokrenuti više puta (idempotentno). Ne briše postojeće transakcije.

-- ===== 1) Status kontrole: nacrt (škart sačuvan) / zavrsena (potvrđena) =====
alter table kontrole add column if not exists status text not null default 'zavrsena';
do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname='kontrole_status_check' and conrelid='kontrole'::regclass) then
    alter table kontrole add constraint kontrole_status_check check (status in ('nacrt','zavrsena'));
  end if;
end $$;

create index if not exists kontrole_draft_idx on kontrole(plant_id, product_id, serija) where status='nacrt';
create unique index if not exists kontrole_draft_u on kontrole(
  plant_id, product_id, serija,
  coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid)
) where status='nacrt';

-- ===== 2) Sačuvaj škart bez potvrde kontrole =====
-- Ponovni poziv mijenja ukupan škart za isti artikal/seriju (ne sabira dva puta).
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
           where p.proname='sacuvaj_skart' and p.pronamespace='public'::regnamespace
  loop execute 'drop function '||f; end loop;
end $$;

create or replace function sacuvaj_skart(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int, p_date date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); tc boolean; cust uuid; ukupno int; d kontrole%rowtype; did uuid;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_skart is null or p_skart < 0 then raise exception 'Neispravan škart'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;
  cust := case when tc then p_customer else null end;
  if cust is not null and not exists(select 1 from customers c
       where c.id=cust and (c.plant_id is null or c.plant_id=p_plant)) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;

  -- Ukupna proizvodnja koja još čeka kontrolu (bez već sačuvanog škarta).
  select coalesce(sum(qty_in),0) into ukupno from movements
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and kind in ('promet','pogon') and (not tc or customer_id=cust);
  if ukupno <= 0 then raise exception 'Nema proizvodnje na čekanju za ovaj artikal'; end if;
  if p_skart > ukupno then raise exception 'Škart (%) je veći od količine na čekanju (%)', p_skart, ukupno; end if;

  select * into d from kontrole
    where plant_id=p_plant and product_id=p_product and serija=s and status='nacrt'
      and (not tc or customer_id=cust)
    order by created_at limit 1;

  if p_skart = 0 then
    if found then
      delete from movements where kontrola_id=d.id and kind='skart';
      delete from kontrole where id=d.id;
    end if;
    return null;
  end if;

  if found then
    did := d.id;
    update kontrole set skart=p_skart, date=coalesce(p_date,date),
      note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=did;
    update movements set qty_out=p_skart, date=coalesce(p_date,date)
      where kontrola_id=did and kind='skart';
    if not found then
      insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
      values(coalesce(p_date,current_date),p_plant,cust,p_product,s,p_skart,'Škart (nacrt)','skart','cekanje',did);
    end if;
  else
    insert into kontrole(date,plant_id,customer_id,product_id,serija,qty,skart,note,status,created_by)
    values(coalesce(p_date,current_date),p_plant,cust,p_product,s,0,p_skart,
      coalesce(nullif(trim(coalesce(p_note,'')),''),'Škart (nacrt)'),'nacrt',auth.uid())
    returning id into did;
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
    values(coalesce(p_date,current_date),p_plant,cust,p_product,s,p_skart,'Škart (nacrt)','skart','cekanje',did);
  end if;
  return did;
end $$;

-- ===== 3) Potvrda kontrole: uvažava već sačuvan škart (nacrt) =====
create or replace function prekontrolisi(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int default null, p_date date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); tc boolean; cust uuid; ukupno int;
        d kontrole%rowtype; did uuid; sk int;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_skart is not null and p_skart < 0 then raise exception 'Neispravan škart'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;
  cust := case when tc then p_customer else null end;
  if cust is not null and not exists(select 1 from customers c
       where c.id=cust and (c.plant_id is null or c.plant_id=p_plant)) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;

  -- Ukupna proizvodnja na čekanju; škart (nacrt) se ne računa kao ulaz.
  select coalesce(sum(qty_in),0) into ukupno from movements
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and kind in ('promet','pogon') and (not tc or customer_id=cust);
  if ukupno <= 0 then raise exception 'Nema proizvodnje na čekanju za ovaj artikal'; end if;

  select * into d from kontrole
    where plant_id=p_plant and product_id=p_product and serija=s and status='nacrt'
      and (not tc or customer_id=cust)
    order by created_at limit 1;

  sk := coalesce(p_skart, case when found then d.skart else 0 end);
  if sk < 0 or sk > ukupno then
    raise exception 'Škart (%) je veći od količine na čekanju (%)', sk, ukupno;
  end if;

  if found then
    did := d.id;
    update kontrole set status='zavrsena', qty=ukupno, skart=sk,
      date=coalesce(p_date,d.date), note=coalesce(nullif(trim(coalesce(p_note,'')),''),note)
      where id=did;
    delete from movements where kontrola_id=did and kind='skart';
    if sk > 0 then
      insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
      values(coalesce(p_date,d.date,current_date),p_plant,cust,p_product,s,sk,
        'Škart pri kontroli','skart','kontrola',did);
    end if;
  else
    did := gen_random_uuid();
    insert into kontrole(id,date,plant_id,customer_id,product_id,serija,qty,skart,note,status,created_by)
    values(did,coalesce(p_date,current_date),p_plant,cust,p_product,s,ukupno,sk,
      nullif(trim(coalesce(p_note,'')),''),'zavrsena',auth.uid());
    if sk > 0 then
      insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
      values(coalesce(p_date,current_date),p_plant,cust,p_product,s,sk,
        'Škart pri kontroli','skart','kontrola',did);
    end if;
  end if;

  update movements set status='kontrola', kontrola_id=did
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and kind in ('promet','pogon') and (not tc or customer_id=cust);
  return did;
end $$;

-- ===== 4) Ispravka škarta: radi i za nacrt i za završenu kontrolu =====
create or replace function uredi_kontrolu(p_id uuid, p_skart int, p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; tc boolean; st int; ukupno int;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovu kontrolu'; end if;
  if p_skart is null or p_skart < 0 then raise exception 'Neispravan škart'; end if;
  select tracks_customer into tc from plants where id=k.plant_id;

  if k.status='nacrt' then
    select coalesce(sum(qty_in),0) into ukupno from movements
      where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija and status='cekanje'
        and kind in ('promet','pogon') and (not tc or customer_id=k.customer_id);
    if ukupno <= 0 then raise exception 'Nema proizvodnje na čekanju za ovaj artikal'; end if;
    if p_skart > ukupno then
      raise exception 'Škart (%) je veći od količine na čekanju (%)', p_skart, ukupno;
    end if;
    if p_skart = 0 then
      delete from movements where kontrola_id=k.id and kind='skart';
      delete from kontrole where id=k.id;
      return;
    end if;
    update kontrole set skart=p_skart, date=coalesce(p_date,date),
      note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=k.id;
    update movements set qty_out=p_skart, date=coalesce(p_date,date), status='cekanje'
      where kontrola_id=k.id and kind='skart';
    if not found then
      insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
      values(coalesce(p_date,k.date,current_date),k.plant_id,k.customer_id,k.product_id,k.serija,p_skart,
        'Škart (nacrt)','skart','cekanje',k.id);
    end if;
    return;
  end if;

  if k.qty > 0 and p_skart > k.qty then
    raise exception 'Škart (%) je veći od kontrolisane količine (%)', p_skart, k.qty;
  end if;

  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija and status='kontrola'
      and (not tc or customer_id=k.customer_id);
  if st < p_skart - k.skart then
    raise exception 'Nema dovoljno prekontrolisanog stanja za taj škart (stanje: %, već izašlo ili iskorišteno)', st;
  end if;

  update kontrole set skart=p_skart, date=coalesce(p_date,date),
    note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=p_id;

  delete from movements where kontrola_id=p_id and kind='skart';
  if p_skart > 0 then
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
    values(coalesce(p_date,k.date), k.plant_id, k.customer_id, k.product_id, k.serija, p_skart,
      'Škart pri kontroli', 'skart', 'kontrola', p_id);
  end if;
end $$;

-- ===== 5) Brisanje: nacrt samo obriše sačuvani škart, završena vraća sve na čekanje =====
create or replace function obrisi_kontrolu(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; tc boolean; st int; ocek int;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovu kontrolu'; end if;

  if k.status='nacrt' then
    delete from movements where kontrola_id=k.id and kind='skart';
    delete from kontrole where id=k.id;
    return;
  end if;

  select tracks_customer into tc from plants where id=k.plant_id;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija and status='kontrola'
      and (not tc or customer_id=k.customer_id);
  select coalesce(sum(qty),0)-coalesce(sum(skart),0) into ocek from kontrole
    where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija and status='zavrsena'
      and (not tc or customer_id=k.customer_id);
  if st < ocek then
    raise exception 'Ne može se poništiti kontrola jer je dio već izašao (preostalo: % kom, očekivano: %)',
      st, ocek;
  end if;

  delete from movements where kontrola_id=p_id and kind='skart';
  update movements set status='cekanje', kontrola_id=null where kontrola_id=p_id;
  delete from kontrole where id=p_id;
end $$;

-- ===== 6) Negativno stanje: kod MOK-a se kupac ne razdvaja =====
-- MOK ulaz može imati kupca kao oznaku, a škart se vodi bez kupca. Zato se
-- provjera stanja kod MOK-a radi po magacinu/proizvodu/seriji, ne po kupcu.
create or replace function ispravi_unos(p_id uuid, p_qty int, p_date date)
returns void language plpgsql security definer set search_path=public as $$
declare r movements%rowtype; r2 movements%rowtype; st int; ns int;
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

create or replace function obrisi_unos(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r movements%rowtype; r2 movements%rowtype; st int; ns int;
begin
  select * into r from movements where id=p_id;
  if not found then raise exception 'Unos ne postoji'; end if;
  if not (is_upravnik() or is_admin() or can_plant(r.plant_id)) then
    raise exception 'Nemate pravo na ovaj unos';
  end if;
  if r.kind='skart' or r.kontrola_id is not null then
    raise exception 'Kontrola je završena. Prvo je obriši u Historiji → Kontrole, pa obriši unos.';
  end if;
  if not (is_upravnik() or is_admin()) and r.kind<>'promet' then
    raise exception 'Vođa može brisati samo svoje ulaze';
  end if;
  if r.kind<>'promet' and r.transfer_id is null and not is_admin() then
    raise exception 'Staro prebacivanje bez veze s parom – obrišite ručno';
  end if;

  -- Brisanje ne smije ostaviti negativno stanje (npr. ulaz čija je roba već izašla).
  for r2 in select * from movements
             where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id)
  loop
    select coalesce(sum(qty_in-qty_out),0) into st from movements m
      where m.plant_id=r2.plant_id and m.product_id=r2.product_id and m.serija=r2.serija
        and m.status=r2.status
        and (exists(select 1 from plants p where p.id=r2.plant_id and not p.tracks_customer)
             or m.customer_id is not distinct from r2.customer_id);
    ns := case when r2.qty_in>0 then st-r2.qty_in else st+r2.qty_out end;
    if ns<0 then
      raise exception 'Brisanje bi dovelo do negativnog stanja (bilo bi % kom)', ns;
    end if;
  end loop;

  delete from movements where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id);
end $$;

grant execute on function ispravi_unos(uuid,int,date) to authenticated;
grant execute on function obrisi_unos(uuid) to authenticated;
grant execute on function sacuvaj_skart(uuid,uuid,uuid,text,int,date,text) to authenticated;
grant execute on function prekontrolisi(uuid,uuid,uuid,text,int,date,text) to authenticated;
grant execute on function uredi_kontrolu(uuid,int,date,text) to authenticated;
grant execute on function obrisi_kontrolu(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ===== Provjere =====
select status, count(*) as kontrola, coalesce(sum(qty),0) as kontrolisano,
       coalesce(sum(skart),0) as skart
from kontrole group by status order by status;

select k.status, k.date, pl.name as magacin, pr.name as proizvod, k.serija, k.qty, k.skart
from kontrole k join plants pl on pl.id=k.plant_id join products pr on pr.id=k.product_id
order by k.created_at desc limit 20;
