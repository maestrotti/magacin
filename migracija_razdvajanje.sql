-- MOK: potpuno odvojeni kupci + historija kontrola i škarta
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor, POSLIJE:
--   schema.sql -> admin.sql -> mok.sql -> migracija_mok.sql -> migracija_mok_nazivi.sql
-- Sigurno je pokrenuti više puta (idempotentno). Ne briše postojeće transakcije.

-- ===== 0) Pomoćne funkcije i kolone (da skripta radi i na starijoj bazi) =====
create extension if not exists pgcrypto with schema extensions;

alter table plants add column if not exists is_main boolean not null default false;
alter table plants add column if not exists is_store boolean not null default false;
alter table plants add column if not exists tracks_customer boolean not null default true;
alter table products add column if not exists plant_id uuid references plants(id) on delete cascade;
alter table customers add column if not exists plant_id uuid references plants(id) on delete cascade;
alter table movements add column if not exists status text not null default 'kontrola';
alter table movements add column if not exists to_plant uuid references plants(id);
alter table movements alter column customer_id drop not null;

create table if not exists stock_customers(
  plant_id uuid not null references plants(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  primary key (plant_id, product_id, customer_id)
);
alter table stock_customers enable row level security;

create or replace function is_admin() returns boolean language sql security definer set search_path=public stable
 as $$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;

-- Glavni magacin: upravnik, admin ili vođa koji ima pristup glavnom magacinu.
create or replace function can_main() returns boolean language sql security definer set search_path=public stable
 as $$ select is_upravnik() or is_admin() or exists(
      select 1 from user_plants up join plants p on p.id=up.plant_id
      where up.user_id=auth.uid() and p.is_main) $$;

do $$ begin
  if not exists(select 1 from plants where lower(name)='pogon mok') then
    raise exception 'Nema Pogona MOK. Prvo pokreni mok.sql (rola postgres), pa ovu skriptu.';
  end if;
end $$;

-- Pogon MOK ne vezuje stanje za kupca (kupci su samo oznake).
update plants set is_store=true where lower(name)='pogon mok';
update plants set tracks_customer=false where lower(name)='pogon mok';

-- ===== 1) Kupci: svaki magacin ima svoje kupce =====
-- Postojeći globalni kupci (plant_id = null) ostaju glavnom magacinu.
-- Ako se isti kupac koristi i u MOK-u, za MOK se pravi njegova kopija.
drop index if exists customers_u;
create unique index if not exists customers_u_global on customers(lower(name)) where plant_id is null;
create unique index if not exists customers_u_plant  on customers(plant_id, lower(name)) where plant_id is not null;

do $$
declare pl record; c record; cid uuid;
begin
  for pl in select id, name from plants where not tracks_customer loop
    for c in
      select distinct cu.id, cu.name
      from customers cu
      where cu.plant_id is null
        and (exists(select 1 from movements m where m.customer_id=cu.id and m.plant_id=pl.id)
          or exists(select 1 from stock_customers sc where sc.customer_id=cu.id and sc.plant_id=pl.id))
      order by cu.name
    loop
      select id into cid from customers
       where plant_id=pl.id and lower(name)=lower(c.name) limit 1;

      -- Uvijek pravi kopiju za MOK; globalni kupac ostaje netaknut za glavni magacin.
      if cid is null then
        insert into customers(name, plant_id) values(c.name, pl.id) returning id into cid;
      end if;
      update movements set customer_id=cid where plant_id=pl.id and customer_id=c.id;
      insert into stock_customers(plant_id, product_id, customer_id)
        select plant_id, product_id, cid from stock_customers
         where plant_id=pl.id and customer_id=c.id
        on conflict do nothing;
      delete from stock_customers where plant_id=pl.id and customer_id=c.id;
    end loop;
  end loop;
end $$;

-- ===== 2) Proizvodi: MOK ima svoje nazive, nezavisno od glavnog magacina =====
drop index if exists products_u;
create unique index if not exists products_u_global on products(lower(name)) where plant_id is null;
create unique index if not exists products_u_plant  on products(plant_id, lower(name)) where plant_id is not null;

do $$
declare pl record; p record; pid uuid;
begin
  for pl in select id, name from plants where not tracks_customer loop
    for p in
      select distinct pr.id, pr.name
      from products pr
      where pr.plant_id is null
        and (exists(select 1 from movements m where m.product_id=pr.id and m.plant_id=pl.id)
          or exists(select 1 from stock_customers sc where sc.product_id=pr.id and sc.plant_id=pl.id))
      order by pr.name
    loop
      select id into pid from products
       where plant_id=pl.id and lower(name)=lower(p.name) limit 1;

      -- Uvijek pravi kopiju za MOK; globalni proizvod ostaje netaknut za glavni magacin.
      if pid is null then
        insert into products(name, plant_id) values(p.name, pl.id) returning id into pid;
      end if;
      update movements set product_id=pid where plant_id=pl.id and product_id=p.id;
      insert into stock_customers(plant_id, product_id, customer_id)
        select plant_id, pid, customer_id from stock_customers
         where plant_id=pl.id and product_id=p.id
        on conflict do nothing;
      delete from stock_customers where plant_id=pl.id and product_id=p.id;
    end loop;
  end loop;
end $$;

-- ===== 3) RLS: MOK vidi svoje, glavni magacin svoje, upravnik/admin sve =====
drop policy if exists "customers read" on customers;
create policy "customers read" on customers for select to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "customers add" on customers;
create policy "customers add" on customers for insert to authenticated
  with check (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "customers edit" on customers;
create policy "customers edit" on customers for update to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)))
  with check (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "customers del" on customers;
create policy "customers del" on customers for delete to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));

drop policy if exists "products read" on products;
create policy "products read" on products for select to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "products add" on products;
create policy "products add" on products for insert to authenticated
  with check (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "products edit" on products;
create policy "products edit" on products for update to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)))
  with check (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));
drop policy if exists "products del" on products;
create policy "products del" on products for delete to authenticated
  using (is_upravnik() or is_admin() or (plant_id is null and can_main()) or (plant_id is not null and can_plant(plant_id)));

drop policy if exists "stock_customers read" on stock_customers;
create policy "stock_customers read" on stock_customers for select to authenticated
  using (can_plant(plant_id) or is_upravnik() or is_admin());
drop policy if exists "stock_customers add" on stock_customers;
create policy "stock_customers add" on stock_customers for insert to authenticated
  with check (can_plant(plant_id) or is_upravnik() or is_admin());
drop policy if exists "stock_customers del" on stock_customers;
create policy "stock_customers del" on stock_customers for delete to authenticated
  using (can_plant(plant_id) or is_upravnik() or is_admin());
grant select, insert, delete on stock_customers to authenticated;

-- ===== 4) Kontrole i škart: posebna historija =====
create table if not exists kontrole(
  id uuid primary key default gen_random_uuid(),
  date date not null default current_date,
  plant_id uuid not null references plants(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  product_id uuid not null references products(id) on delete cascade,
  serija text not null default '',
  qty int not null default 0 check (qty>=0),
  skart int not null default 0 check (skart>=0),
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);

alter table movements add column if not exists kontrola_id uuid references kontrole(id) on delete set null;
create index if not exists kontrole_date_idx on kontrole(date desc, id);
create index if not exists kontrole_plant_idx on kontrole(plant_id, date desc);
create index if not exists movements_kontrola_idx on movements(kontrola_id);

alter table kontrole enable row level security;
drop policy if exists "kontrole read" on kontrole;
create policy "kontrole read" on kontrole for select to authenticated
  using (is_upravnik() or is_admin() or can_plant(plant_id));
drop policy if exists "kontrole del" on kontrole;
create policy "kontrole del" on kontrole for delete to authenticated
  using (is_admin());
grant select, delete on kontrole to authenticated;

-- ===== 5) Stari podaci: napravi kontrolu za već prekontrolisane unose =====
-- Tako se i stare kontrole mogu naći u historiji i poništiti.
do $$
declare m record; kid uuid;
begin
  for m in
    select m2.* from movements m2 join plants pl on pl.id=m2.plant_id
     where not pl.tracks_customer and m2.kind in ('promet','pogon') and m2.qty_in>0
       and m2.status='kontrola' and m2.kontrola_id is null
  loop
    kid := gen_random_uuid();
    insert into kontrole(id,date,plant_id,customer_id,product_id,serija,qty,skart,note,created_by,created_at)
    values(kid, m.date, m.plant_id, m.customer_id, m.product_id, m.serija, m.qty_in, 0,
      'Stara kontrola (automatski preuzeta)', m.created_by, coalesce(m.created_at, now()));
    update movements set kontrola_id=kid where id=m.id;
  end loop;
end $$;

-- Stari škart unosi dobijaju svoj zapis u historiji škarta.
do $$
declare s record; kid uuid;
begin
  for s in select * from movements where kind='skart' and kontrola_id is null
  loop
    kid := gen_random_uuid();
    insert into kontrole(id,date,plant_id,customer_id,product_id,serija,qty,skart,note,created_by,created_at)
    values(kid, s.date, s.plant_id, s.customer_id, s.product_id, s.serija, 0, s.qty_out,
      'Stari škart (automatski preuzet)', s.created_by, coalesce(s.created_at, now()));
    update movements set kontrola_id=kid where id=s.id;
  end loop;
end $$;

-- ===== 6) Kontrola: škart umanjuje stanje, ostatak je spreman za izlaz =====
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
           where p.proname='prekontrolisi' and p.pronamespace='public'::regnamespace
  loop execute 'drop function '||f; end loop;
end $$;

create or replace function prekontrolisi(p_plant uuid, p_customer uuid, p_product uuid, p_serija text,
  p_skart int default 0, p_date date default current_date, p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare s text := coalesce(p_serija,''); st int; tc boolean; kid uuid := gen_random_uuid(); cust uuid;
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

  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and (not tc or customer_id=cust);
  if st <= 0 then raise exception 'Nema proizvodnje na čekanju za ovaj artikal'; end if;
  if p_skart > st then raise exception 'Škart (%) je veći od količine na čekanju (%)', p_skart, st; end if;

  insert into kontrole(id,date,plant_id,customer_id,product_id,serija,qty,skart,note,created_by)
  values(kid, coalesce(p_date,current_date), p_plant, cust, p_product, s, st, p_skart,
    nullif(trim(coalesce(p_note,'')),''), auth.uid());

  update movements set status='kontrola', kontrola_id=kid
    where plant_id=p_plant and product_id=p_product and serija=s and status='cekanje'
      and (not tc or customer_id=cust);

  if p_skart > 0 then
    insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,status,kontrola_id)
    values(coalesce(p_date,current_date), p_plant, cust, p_product, s, p_skart,
      'Škart pri kontroli', 'skart', 'kontrola', kid);
  end if;
  return kid;
end $$;

-- Ispravka škarta/datuma kontrole. Stanje se automatski koriguje.
create or replace function uredi_kontrolu(p_id uuid, p_skart int, p_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; tc boolean; st int;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovu kontrolu'; end if;
  if p_skart is null or p_skart < 0 then raise exception 'Neispravan škart'; end if;
  if k.qty > 0 and p_skart > k.qty then
    raise exception 'Škart (%) je veći od kontrolisane količine (%)', p_skart, k.qty;
  end if;

  select tracks_customer into tc from plants where id=k.plant_id;
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

-- Poništavanje kontrole: unos se vraća na čekanje, škart se vraća u stanje.
create or replace function obrisi_kontrolu(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare k kontrole%rowtype; tc boolean; st int; ocek int;
begin
  select * into k from kontrole where id=p_id;
  if not found then raise exception 'Kontrola ne postoji'; end if;
  if not (can_plant(k.plant_id) or is_upravnik() or is_admin()) then raise exception 'Nemate pravo na ovu kontrolu'; end if;

  select tracks_customer into tc from plants where id=k.plant_id;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija and status='kontrola'
      and (not tc or customer_id=k.customer_id);
  -- Očekivano prekontrolisano stanje = sve kontrole minus sav škart za isti artikal/seriju.
  -- Ako je st manji, dio je već izašao, pa se kontrola ne smije poništiti.
  select coalesce(sum(qty),0)-coalesce(sum(skart),0) into ocek from kontrole
    where plant_id=k.plant_id and product_id=k.product_id and serija=k.serija
      and (not tc or customer_id=k.customer_id);
  if st < ocek then
    raise exception 'Ne može se poništiti kontrola jer je dio već izašao (preostalo: % kom, očekivano: %)',
      st, ocek;
  end if;

  delete from movements where kontrola_id=p_id and kind='skart';
  update movements set status='cekanje', kontrola_id=null where kontrola_id=p_id;
  delete from kontrole where id=p_id;
end $$;

-- ===== 7) Izlaz: kupac mora pripadati magacinu =====
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
           where p.proname='izlaz' and p.pronamespace='public'::regnamespace
  loop execute 'drop function '||f; end loop;
end $$;
create or replace function izlaz(p_plant uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int, p_to uuid,
  p_date date default current_date, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; s text := coalesce(p_serija,''); tn text; tc boolean;
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select name into tn from plants where id=p_to;
  if tn is null then raise exception 'Nepoznat pogon / odredište'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;
  if p_customer is not null and not exists(select 1 from customers c
       where c.id=p_customer and (c.plant_id is null or c.plant_id=p_plant)) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;

  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=s and status='kontrola'
      and (not tc or customer_id=p_customer);
  if p_qty>st then raise exception 'Količina je veća od prekontrolisanog stanja (stanje: %)', st; end if;
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,to_plant,status)
  values(p_date,p_plant,p_customer,p_product,s,p_qty,
    concat_ws(' · ','Izlaz u pogon: '||tn,nullif(p_note,'')),'izlaz',gen_random_uuid(),p_to,'kontrola');
end $$;

-- Prebacivanje na drugog kupca: oba kupca moraju pripadati istom magacinu.
create or replace function transfer_stock(p_plant uuid, p_product uuid, p_serija text, p_from uuid, p_to uuid,
  p_qty int default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; q int; fn text; tn text; tid uuid := gen_random_uuid(); tc boolean;
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo'; end if;
  if p_from=p_to then raise exception 'Odaberite drugog kupca'; end if;
  select tracks_customer into tc from plants where id=p_plant;
  if tc is null then raise exception 'Nepoznat magacin'; end if;
  if not exists(select 1 from customers c
       where c.id=p_from and (c.plant_id=p_plant or (c.plant_id is null and tc))) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;
  if not exists(select 1 from customers c
       where c.id=p_to and (c.plant_id=p_plant or (c.plant_id is null and tc))) then
    raise exception 'Kupac ne pripada ovom magacinu';
  end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and product_id=p_product and serija=p_serija and customer_id=p_from and status='kontrola';
  q := coalesce(p_qty, st);
  if q<=0 or q>st then raise exception 'Neispravna kolicina (stanje: %)', st; end if;
  select name into fn from customers where id=p_from; select name into tn from customers where id=p_to;
  insert into movements(plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,status)
  values(p_plant,p_from,p_product,p_serija,q,'Prebaceno na: '||tn,'prebacivanje',tid,'kontrola');
  insert into movements(plant_id,customer_id,product_id,serija,qty_in,note,kind,transfer_id,status)
  values(p_plant,p_to,p_product,p_serija,q,'Prebaceno sa: '||fn,'prebacivanje',tid,'kontrola');
end $$;

-- ===== 8) Ispravka/brisanje unosa: vođa smije svoj ulaz, ali ne prekontrolisan =====
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
        and m.status=r2.status and m.customer_id is not distinct from r2.customer_id;
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
        and m.status=r2.status and m.customer_id is not distinct from r2.customer_id;
    ns := case when r2.qty_in>0 then st-r2.qty_in else st+r2.qty_out end;
    if ns<0 then
      raise exception 'Brisanje bi dovelo do negativnog stanja (bilo bi % kom)', ns;
    end if;
  end loop;

  delete from movements where id=p_id or (r.transfer_id is not null and transfer_id=r.transfer_id);
end $$;

-- ===== 9) RLS: direktno se smije brisati samo ulaz koji još nije kontrolisan =====
drop policy if exists "mov add" on movements;
create policy "mov add" on movements for insert to authenticated
  with check (can_plant(plant_id) and kind='promet' and qty_in>0 and kontrola_id is null);
drop policy if exists "mov del" on movements;
create policy "mov del" on movements for delete to authenticated
  using (can_plant(plant_id) and kind='promet' and status='cekanje' and kontrola_id is null);

grant execute on function prekontrolisi(uuid,uuid,uuid,text,int,date,text) to authenticated;
grant execute on function uredi_kontrolu(uuid,int,date,text) to authenticated;
grant execute on function obrisi_kontrolu(uuid) to authenticated;
grant execute on function can_main() to authenticated;

notify pgrst, 'reload schema';

-- ===== Provjere =====
select coalesce(pl.name,'glavni / zajednički') as magacin, count(*) as kupaca
from customers c left join plants pl on pl.id=c.plant_id
group by 1 order by 1;

select coalesce(pl.name,'glavni / zajednički') as magacin, count(*) as proizvoda
from products p left join plants pl on pl.id=p.plant_id
group by 1 order by 1;

select count(*) as kontrola,
       coalesce(sum(qty),0) as kontrolisano,
       coalesce(sum(skart),0) as skart
from kontrole;

select k.date, pl.name as magacin, pr.name as proizvod, k.serija, k.qty, k.skart
from kontrole k join plants pl on pl.id=k.plant_id join products pr on pr.id=k.product_id
order by k.date desc, k.created_at desc limit 20;
