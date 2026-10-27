-- MOK: dnevna (djelimična) kontrola, odvojeni unosi škarta i konačna potvrda
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor, POSLIJE migracija_skart_nacrt.sql.
-- Sigurno je pokrenuti više puta (idempotentno). Ne briše postojeće transakcije.
--
-- Model:
--   * Proizvodnja (ulaz) ostaje status 'cekanje'.
--   * Svaki unos škarta je poseban zapis u kontrole (tip='skart'); više unosa se sabira.
--   * Svaka kontrola je poseban zapis u kontrole (tip='kontrola'); kontrola može biti
--     dnevna/djelimična (npr. danas 500, sutra 500).
--   * Kontrola pravi dva interna kretanja:
--       kontrola_out  qty_out = qty, status 'cekanje'  (skida sa čekanja)
--       kontrola_in   qty_in  = qty, status 'kontrola'  (dodaje u spremno za izlaz)
--   * Konačna potvrda ("sve prekontrolisano") se pamti u mok_potvrde i moguća je
--     samo kada je na čekanju 0 (proizvedeno = škart + prekontrolisano).
--   * Glavni magacin se ne mijenja: sve nove funkcije rade samo za magacine
--     sa plants.tracks_customer = false (Pogon MOK).

-- ===== 1) Tip zapisa u kontrole =====
alter table kontrole add column if not exists status text not null default 'zavrsena';
alter table kontrole add column if not exists tip text not null default 'kontrola';
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname='kontrole_tip_check' and conrelid='kontrole'::regclass) then
    alter table kontrole add constraint kontrole_tip_check check (tip in ('kontrola','skart'));
  end if;
  if not exists (select 1 from pg_constraint
                  where conname='kontrole_status_check' and conrelid='kontrole'::regclass) then
    alter table kontrole add constraint kontrole_status_check check (status in ('nacrt','zavrsena'));
  end if;
end $$;

-- Stari "nacrt" je bio sačuvan škart prije potvrde kontrole. Novi model ga vodi kao
-- poseban unos škarta, pa ga ovdje samo označimo (ne brišemo i ne mijenjamo stanje).
update kontrole set tip='skart'
 where tip<>'skart' and (status='nacrt' or (coalesce(qty,0)=0 and coalesce(skart,0)>0));
update kontrole set tip='kontrola' where tip is null;

create index if not exists kontrole_tip_idx on kontrole(plant_id, tip, date desc);
drop index if exists kontrole_draft_u; -- novi model ne koristi jedan zajednički nacrt

-- ===== 2) Konačna potvrda da je sve prekontrolisano =====
create table if not exists mok_potvrde(
  plant_id uuid not null references plants(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  serija text not null default '',
  produced int not null default 0,
  skart int not null default 0,
  controlled int not null default 0,
  date date not null default current_date,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now(),
  primary key(plant_id, product_id, serija)
);
alter table mok_potvrde enable row level security;
drop policy if exists "mok_potvrde read" on mok_potvrde;
create policy "mok_potvrde read" on mok_potvrde for select to authenticated
  using (is_upravnik() or is_admin() or can_plant(plant_id));
grant select on mok_potvrde to authenticated;

-- ===== 3) Stanje: interna kontrola ulazi u odgovarajuće stanje =====
create or replace view v_stock with (security_invoker=true) as
-- Glavni magacin i drugi magacini: stanje se prati po kupcu
select m.plant_id, p.name plant, m.customer_id, coalesce(c.name,'') customer,
  m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon','kontrola_in')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz','skart','kontrola_out')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out,
  m.status,
  coalesce(sum(m.qty_out) filter (where m.kind='kontrola_out'),0)::int qty_kontrola,
  coalesce(sum(m.qty_out) filter (where m.kind='skart'),0)::int qty_skart,
  coalesce(sum(m.qty_out) filter (where m.kind in ('otprema','izlaz')),0)::int qty_izlaz,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_proizvodnja
from movements m
join plants p on p.id=m.plant_id
join products pr on pr.id=m.product_id
left join customers c on c.id=m.customer_id
where p.tracks_customer
group by 1,2,3,4,5,6,7,m.status
union all
-- Pogon MOK: stanje po proizvodu i seriji, kupac je samo oznaka
select m.plant_id, p.name plant, null::uuid customer_id, ''::text customer,
  m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon','kontrola_in')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz','skart','kontrola_out')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out,
  m.status,
  coalesce(sum(m.qty_out) filter (where m.kind='kontrola_out'),0)::int qty_kontrola,
  coalesce(sum(m.qty_out) filter (where m.kind='skart'),0)::int qty_skart,
  coalesce(sum(m.qty_out) filter (where m.kind in ('otprema','izlaz')),0)::int qty_izlaz,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_proizvodnja
from movements m
join plants p on p.id=m.plant_id
join products pr on pr.id=m.product_id
where not p.tracks_customer
group by 1,2,3,4,5,6,7,m.status;

-- ===== 4) Pomoćne funkcije: ukupno proizvedeno / škart / kontrolisano =====
create or replace function mok_totals(p_plant uuid, p_product uuid, p_serija text)
returns table(produced int, skart int, controlled int, exited int, pending int, available int)
language sql security definer set search_path=public stable as $$
  with b as (
    select
      coalesce((select sum(m.qty_in) from movements m
        where m.plant_id=p_plant and m.product_id=p_product
          and coalesce(m.serija,'')=coalesce(p_serija,'')
          and m.kind in ('promet','pogon') and m.qty_in>0),0)::int produced,
      coalesce((select sum(k.skart) from kontrole k
        where k.plant_id=p_plant and k.product_id=p_product
          and coalesce(k.serija,'')=coalesce(p_serija,'')),0)::int skart,
      coalesce((select sum(greatest(coalesce(k.qty,0)-coalesce(k.skart,0),0)) from kontrole k
        where k.plant_id=p_plant and k.product_id=p_product
          and coalesce(k.serija,'')=coalesce(p_serija,'')
          and coalesce(k.tip,'kontrola')<>'skart'
          and coalesce(k.status,'zavrsena')<>'nacrt'),0)::int controlled,
      coalesce((select sum(m.qty_out) from movements m
        where m.plant_id=p_plant and m.product_id=p_product
          and coalesce(m.serija,'')=coalesce(p_serija,'')
          and m.kind='izlaz'),0)::int exited
  )
  select b.produced, b.skart, b.controlled, b.exited,
    (b.produced-b.skart-b.controlled)::int pending,
    (b.controlled-b.exited)::int available
  from b;
$$;

-- Provjeri da je magacin MOK (kupac je samo oznaka, ne dijeli stanje).
create or replace function mok_plant(p_plant uuid) returns boolean
language sql security definer set search_path=public stable as $$
  select exists(select 1 from plants p where p.id=p_plant and not p.tracks_customer);
$$;

-- ===== 5) Novi unos škarta (dodaje se na ukupan škart) =====
create or replace function dodaj_skart(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_qty int, p_date date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); cust uuid; did uuid; t record; vdate date;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if not mok_plant(p_plant) then raise exception 'Škart se unosi samo u Pogon MOK'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Količina škarta mora biti veća od 0'; end if;
  select * into t from mok_totals(p_plant,p_product,s);
  if p_qty > t.pending then
    raise exception 'Škart (%) je veći od proizvodnje na čekanju (%)', p_qty, t.pending;
  end if;
  cust := p_customer;
  if cust is not null and not exists(select 1 from customers c
       where c.id=cust and (c.plant_id is null or c.plant_id=p_plant)) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;
  vdate := coalesce(p_date, current_date);

  insert into kontrole(date,plant_id,customer_id,product_id,serija,qty,skart,note,tip,status,created_by)
  values(vdate,p_plant,cust,p_product,s,0,p_qty,
    nullif(trim(coalesce(p_note,'')),''),'skart','zavrsena',auth.uid())
  returning id into did;

  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
  values(vdate,p_plant,cust,p_product,s,p_qty,
    coalesce(nullif(trim(coalesce(p_note,'')),''),'Škart'),'skart','cekanje',did);
  return did;
end $$;

-- ===== 6) Ispravka i brisanje pojedinačnog unosa škarta =====
create or replace function ispravi_skart(p_id uuid, p_qty int, p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; t record; dostupno int; vdate date;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Unos škarta ne postoji'; end if;
  if coalesce(k.tip,'kontrola')<>'skart' then raise exception 'To nije unos škarta'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if p_qty is null or p_qty<=0 then raise exception 'Količina škarta mora biti veća od 0'; end if;
  select * into t from mok_totals(k.plant_id,k.product_id,k.serija);
  dostupno := t.pending + coalesce(k.skart,0);
  if p_qty > dostupno then
    raise exception 'Škart (%) je veći od proizvodnje na čekanju (%)', p_qty, dostupno;
  end if;
  vdate := coalesce(p_date,k.date,current_date);

  update kontrole set skart=p_qty, date=vdate,
    note=coalesce(nullif(trim(coalesce(p_note,'')),''),note)
   where id=p_id;

  update movements set qty_out=p_qty, date=vdate,
    note=coalesce(nullif(trim(coalesce(p_note,'')),''),note)
   where kontrola_id=p_id and kind='skart';
  if not found then
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
    values(vdate,k.plant_id,k.customer_id,k.product_id,k.serija,p_qty,
      coalesce(nullif(trim(coalesce(p_note,'')),''),'Škart'),'skart','cekanje',p_id);
  end if;
end $$;

create or replace function obrisi_skart(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Unos škarta ne postoji'; end if;
  if coalesce(k.tip,'kontrola')<>'skart' then raise exception 'To nije unos škarta'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  delete from movements where kontrola_id=p_id and kind='skart';
  delete from kontrole where id=p_id;
end $$;

-- ===== 7) Novi unos kontrole (dnevna / djelimična) =====
create or replace function dodaj_kontrolu(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_qty int, p_date date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); cust uuid; did uuid; t record; vdate date;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if not mok_plant(p_plant) then raise exception 'Kontrola se unosi samo u Pogon MOK'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Količina za kontrolu mora biti veća od 0'; end if;
  select * into t from mok_totals(p_plant,p_product,s);
  if p_qty > t.pending then
    raise exception 'Količina je veća od proizvodnje na čekanju (dostupno: %)', t.pending;
  end if;
  cust := p_customer;
  if cust is not null and not exists(select 1 from customers c
       where c.id=cust and (c.plant_id is null or c.plant_id=p_plant)) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;
  vdate := coalesce(p_date, current_date);

  insert into kontrole(date,plant_id,customer_id,product_id,serija,qty,skart,note,tip,status,created_by)
  values(vdate,p_plant,cust,p_product,s,p_qty,0,
    nullif(trim(coalesce(p_note,'')),''),'kontrola','zavrsena',auth.uid())
  returning id into did;

  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
  values(vdate,p_plant,cust,p_product,s,p_qty,'Prekontrolisano (odvojeno)','kontrola_out','cekanje',did);
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_in,note,kind,status,kontrola_id)
  values(vdate,p_plant,cust,p_product,s,p_qty,'Prekontrolisano','kontrola_in','kontrola',did);
  return did;
end $$;

-- ===== 8) Ispravka i brisanje jedne kontrole =====
create or replace function ispravi_kontrolu(p_id uuid, p_qty int, p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; t record; co int; ci int; cs int; dostupno int; vdate date;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if coalesce(k.tip,'kontrola')='skart' then raise exception 'To je unos škarta, ne kontrola'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if p_qty is null or p_qty<=0 then raise exception 'Količina za kontrolu mora biti veća od 0'; end if;
  vdate := coalesce(p_date,k.date,current_date);

  select coalesce(sum(qty_out),0) into co from movements
    where kontrola_id=p_id and kind='kontrola_out';
  select coalesce(sum(qty_in),0) into ci from movements
    where kontrola_id=p_id and kind='kontrola_in';
  if co=0 and ci=0 then
    -- Stara kontrola (prije djelimične kontrole): može se mijenjati samo datum/napomena.
    if p_qty<>coalesce(k.qty,0) then
      raise exception 'Kod stare kontrole količinu nije moguće mijenjati (samo datum i napomenu)';
    end if;
    update kontrole set date=vdate,
      note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=p_id;
    return;
  end if;

  select * into t from mok_totals(k.plant_id,k.product_id,k.serija);
  dostupno := t.pending + co;
  if p_qty > dostupno then
    raise exception 'Količina je veća od proizvodnje na čekanju (dostupno: %)', dostupno;
  end if;
  cs := greatest(coalesce(k.qty,0)-coalesce(k.skart,0),0);
  if t.available - cs + p_qty < 0 then
    raise exception 'Nema dovoljno prekontrolisanog stanja za tu izmjenu (dostupno: %)', t.available;
  end if;

  update kontrole set qty=p_qty, date=vdate,
    note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=p_id;
  update movements set qty_out=p_qty, date=vdate
    where kontrola_id=p_id and kind='kontrola_out';
  update movements set qty_in=p_qty, date=vdate
    where kontrola_id=p_id and kind='kontrola_in';
end $$;

create or replace function obrisi_kontrolu(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; t record; cs int;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovu kontrolu';
  end if;
  if coalesce(k.tip,'kontrola')='skart' then
    perform obrisi_skart(p_id);
    return;
  end if;

  select * into t from mok_totals(k.plant_id,k.product_id,k.serija);
  cs := greatest(coalesce(k.qty,0)-coalesce(k.skart,0),0);
  if t.available < cs then
    raise exception 'Ne može se poništiti kontrola jer je dio već izašao (dostupno: % kom, potrebno: %)',
      t.available, cs;
  end if;

  -- Interna kretanja nove kontrole se brišu; stari ulaz (ako postoji) vraća se na čekanje.
  delete from movements where kontrola_id=p_id and kind in ('kontrola_out','kontrola_in','skart');
  update movements set status='cekanje', kontrola_id=null where kontrola_id=p_id;
  delete from kontrole where id=p_id;
end $$;

-- ===== 9) Konačna potvrda: sve je prekontrolisano, spremno za izlaz =====
create or replace function potvrdi_kontrolu(p_plant uuid, p_product uuid, p_serija text, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); t record;
begin
  if not (can_plant(p_plant) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovaj magacin';
  end if;
  if not mok_plant(p_plant) then raise exception 'Potvrda je moguća samo za Pogon MOK'; end if;
  select * into t from mok_totals(p_plant,p_product,s);
  if t.produced<=0 then raise exception 'Nema proizvodnje za ovaj artikal'; end if;
  if t.pending<0 then raise exception 'Stanje nije ispravno (na čekanju: %)', t.pending; end if;
  if t.pending<>0 then
    raise exception 'Nije sve prekontrolisano. Na čekanju je još % kom.', t.pending;
  end if;
  insert into mok_potvrde(plant_id,product_id,serija,produced,skart,controlled,date,note,created_by,created_at)
  values(p_plant,p_product,s,t.produced,t.skart,t.controlled,current_date,
    nullif(trim(coalesce(p_note,'')),''),auth.uid(),now())
  on conflict (plant_id,product_id,serija) do update set
    produced=excluded.produced, skart=excluded.skart, controlled=excluded.controlled,
    date=excluded.date, note=excluded.note, created_by=excluded.created_by, created_at=now();
end $$;

-- Svaka promjena proizvodnje/škarta/kontrole poništava staru potvrdu (mora se ponovo potvrditi).
-- Izlaz (kada roba ode na Laboraciju) NE poništava potvrdu – on ne mijenja proizvedeno/škart/prekontrolisano.
create or replace function mok_invalidate_potvrda() returns trigger
language plpgsql security definer set search_path=public as $$
declare r movements%rowtype;
begin
  r := case when tg_op='DELETE' then old else new end;
  if r.kind in ('promet','pogon','skart','kontrola_in','kontrola_out')
     and exists(select 1 from plants p where p.id=r.plant_id and not p.tracks_customer) then
    delete from mok_potvrde where plant_id=r.plant_id and product_id=r.product_id
      and serija=coalesce(r.serija,'');
  end if;
  return null;
end $$;

drop trigger if exists mok_invalidate_potvrda on movements;
create trigger mok_invalidate_potvrda after insert or update or delete on movements
for each row execute function mok_invalidate_potvrda();

-- ===== 10) Kompatibilnost sa starim dugmadima (stari keš aplikacije) =====
do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p
    where p.proname in ('prekontrolisi','sacuvaj_skart') and p.pronamespace='public'::regnamespace
  loop execute 'drop function '||f; end loop;
end $$;

-- Stari poziv "Prekontrolisano": škart se dodaje kao poseban unos, a ostatak (ili p_kolicina)
-- se kontroliše. Novi UI koristi dodaj_kontrolu / dodaj_skart direktno.
create or replace function prekontrolisi(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int default null, p_date date default null, p_note text default null, p_kolicina int default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare t record; q int; did uuid;
begin
  if coalesce(p_skart,0)>0 then
    perform dodaj_skart(p_plant,p_customer,p_product,p_serija,p_skart,p_date,p_note);
  end if;
  select * into t from mok_totals(p_plant,p_product,coalesce(p_serija,''));
  q := coalesce(p_kolicina,t.pending);
  if q>0 then did := dodaj_kontrolu(p_plant,p_customer,p_product,p_serija,q,p_date,p_note); end if;
  return did;
end $$;

-- Stari poziv "Sačuvaj škart bez potvrde": dodaje novi unos škarta.
create or replace function sacuvaj_skart(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int, p_date date default null, p_note text default null, p_kolicina int default null)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if coalesce(p_skart,0)<=0 then return null; end if;
  return dodaj_skart(p_plant,p_customer,p_product,p_serija,p_skart,p_date,p_note);
end $$;

-- Stari poziv za izmjenu: škart mijenja pojedinačni unos, kontrola samo datum/napomenu.
create or replace function uredi_kontrolu(p_id uuid, p_skart int, p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then
    raise exception 'Nemate pravo na ovu kontrolu';
  end if;
  if coalesce(k.tip,'kontrola')='skart' then
    if coalesce(p_skart,0)<=0 then perform obrisi_skart(p_id);
    else perform ispravi_skart(p_id,p_skart,p_date,p_note); end if;
  else
    update kontrole set date=coalesce(p_date,date),
      note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=p_id;
  end if;
end $$;

-- ===== 11) Dozvole =====
grant execute on function mok_totals(uuid,uuid,text) to authenticated;
grant execute on function mok_plant(uuid) to authenticated;
grant execute on function dodaj_skart(uuid,uuid,uuid,text,int,date,text) to authenticated;
grant execute on function ispravi_skart(uuid,int,date,text) to authenticated;
grant execute on function obrisi_skart(uuid) to authenticated;
grant execute on function dodaj_kontrolu(uuid,uuid,uuid,text,int,date,text) to authenticated;
grant execute on function ispravi_kontrolu(uuid,int,date,text) to authenticated;
grant execute on function obrisi_kontrolu(uuid) to authenticated;
grant execute on function potvrdi_kontrolu(uuid,uuid,text,text) to authenticated;
grant execute on function prekontrolisi(uuid,uuid,uuid,text,int,date,text,int) to authenticated;
grant execute on function sacuvaj_skart(uuid,uuid,uuid,text,int,date,text,int) to authenticated;
grant execute on function uredi_kontrolu(uuid,int,date,text) to authenticated;

notify pgrst, 'reload schema';

-- ===== Provjere =====
select 'kontrole.tip' as provjera, count(*) as ima
from information_schema.columns
where table_schema='public' and table_name='kontrole' and column_name='tip';

select 'mok_potvrde' as provjera, count(*) as ima
from information_schema.tables
where table_schema='public' and table_name='mok_potvrde';

select 'v_stock.kontrola_in' as provjera, count(*) as ima
from information_schema.columns
where table_schema='public' and table_name='v_stock' and column_name='qty_kontrola';

select 'funkcije' as provjera, count(*) as ima
from pg_proc
where proname in ('dodaj_skart','ispravi_skart','obrisi_skart','dodaj_kontrolu','ispravi_kontrolu',
  'obrisi_kontrolu','potvrdi_kontrolu','mok_totals')
  and pronamespace='public'::regnamespace;

select pl.name as magacin, pr.name as proizvod, k.serija, k.tip, k.date, k.qty, k.skart
from kontrole k
join plants pl on pl.id=k.plant_id
join products pr on pr.id=k.product_id
order by k.date desc, k.created_at desc
limit 20;
