-- KOMPLETNA BAZA (pokreni kao rola postgres, na praznoj bazi ili poslije reset.sql)
create extension if not exists pgcrypto with schema extensions;

create table plants(id uuid primary key default gen_random_uuid(), name text not null);
create unique index plants_u on plants((lower(name)));
create table profiles(id uuid primary key references auth.users on delete cascade, email text, full_name text,
  role text not null default 'vodja' check (role in ('vodja','upravnik')), plant_id uuid references plants);
create table user_plants(user_id uuid references auth.users on delete cascade, plant_id uuid references plants on delete cascade, primary key(user_id,plant_id));
create table customers(id uuid primary key default gen_random_uuid(), name text not null);
create unique index customers_u on customers((lower(name)));
create table products(id uuid primary key default gen_random_uuid(), name text not null);   -- name = sifra artikla (LP-1...)
create unique index products_u on products((lower(name)));
create table movements(id uuid primary key default gen_random_uuid(), date date not null default current_date,
  plant_id uuid not null references plants, customer_id uuid not null references customers, product_id uuid not null references products,
  serija text not null default '',
  qty_in int not null default 0 check (qty_in>=0), qty_out int not null default 0 check (qty_out>=0),
  note text, kind text not null default 'promet', created_by uuid default auth.uid(), created_at timestamptz default now(),
  check ((qty_in>0) <> (qty_out>0)));

create function is_upravnik() returns boolean language sql security definer set search_path=public stable
 as $$ select exists(select 1 from profiles where id=auth.uid() and role='upravnik') $$;
create function can_plant(pid uuid) returns boolean language sql security definer set search_path=public stable
 as $$ select exists(select 1 from user_plants where user_id=auth.uid() and plant_id=pid) $$;

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare pid uuid; pn text := nullif(trim(new.raw_user_meta_data->>'plant'),'');
begin
  if pn is not null then
    insert into plants(name) values(pn) on conflict ((lower(name))) do nothing;
    select id into pid from plants where lower(name)=lower(pn);
  end if;
  insert into profiles(id,email,full_name,role,plant_id)
  values(new.id,new.email,new.raw_user_meta_data->>'name',
         case when lower(new.email)='o.senad@pobjeda.com' then 'upravnik' else 'vodja' end, pid);
  if pid is not null then insert into user_plants values(new.id,pid) on conflict do nothing; end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

alter table plants enable row level security; alter table profiles enable row level security; alter table user_plants enable row level security;
alter table customers enable row level security; alter table products enable row level security; alter table movements enable row level security;
create policy "plants read" on plants for select to anon, authenticated using (true);
create policy "profiles read" on profiles for select to authenticated using (id=auth.uid() or is_upravnik());
create policy "up read" on user_plants for select to authenticated using (user_id=auth.uid() or is_upravnik());
create policy "customers read" on customers for select to authenticated using (true);
create policy "customers add" on customers for insert to authenticated with check (true);
create policy "products read" on products for select to authenticated using (true);
create policy "products add" on products for insert to authenticated with check (true);
create policy "mov read" on movements for select to authenticated using (is_upravnik() or can_plant(plant_id));
create policy "mov add" on movements for insert to authenticated with check (can_plant(plant_id));
create policy "mov del" on movements for delete to authenticated using (can_plant(plant_id));

create view v_stock with (security_invoker=true) as
select m.plant_id, p.name plant, m.customer_id, c.name customer, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind='promet'),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind='promet'),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind='promet' and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind='promet' and m.qty_out>0) last_out
from movements m join plants p on p.id=m.plant_id join customers c on c.id=m.customer_id join products pr on pr.id=m.product_id
group by 1,2,3,4,5,6,7;

create function transfer_stock(p_plant uuid, p_product uuid, p_serija text, p_from uuid, p_to uuid, p_qty int default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; q int; fn text; tn text;
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo'; end if;
  if p_from=p_to then raise exception 'Odaberite drugog kupca'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements where plant_id=p_plant and product_id=p_product and serija=p_serija and customer_id=p_from;
  q := coalesce(p_qty, st);
  if q<=0 or q>st then raise exception 'Neispravna količina (stanje: %)', st; end if;
  select name into fn from customers where id=p_from; select name into tn from customers where id=p_to;
  insert into movements(plant_id,customer_id,product_id,serija,qty_out,note,kind) values(p_plant,p_from,p_product,p_serija,q,'Prebačeno na: '||tn,'prebacivanje');
  insert into movements(plant_id,customer_id,product_id,serija,qty_in,note,kind) values(p_plant,p_to,p_product,p_serija,q,'Prebačeno sa: '||fn,'prebacivanje');
end $$;

create function transfer_plants(p_from uuid, p_to uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int)
returns void language plpgsql security definer set search_path=public as $$
declare st int; fn text; tn text;
begin
  if not (can_plant(p_from) and can_plant(p_to)) then raise exception 'Nemate pravo na oba pogona'; end if;
  if p_from=p_to then raise exception 'Odaberite drugi pogon'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements where plant_id=p_from and product_id=p_product and serija=p_serija and customer_id=p_customer;
  if p_qty<=0 or p_qty>st then raise exception 'Neispravna količina (stanje: %)', st; end if;
  select name into fn from plants where id=p_from; select name into tn from plants where id=p_to;
  insert into movements(plant_id,customer_id,product_id,serija,qty_out,note,kind) values(p_from,p_customer,p_product,p_serija,p_qty,'Prebačeno u pogon: '||tn,'prebacivanje');
  insert into movements(plant_id,customer_id,product_id,serija,qty_in,note,kind) values(p_to,p_customer,p_product,p_serija,p_qty,'Prebačeno iz pogona: '||fn,'prebacivanje');
end $$;

-- POGONI I KORISNICI (lozinke promijeniti nakon prve prijave)
insert into plants(name) values('12'),('12A'),('24A');

do $$
declare u record; uid uuid;
begin
  for u in select * from (values
    ('o.senad@pobjeda.com','123Pobjeda','Senad'),
    ('k.belmin@pobjeda.com','1234Pobjeda','Belmin Korda')) t(email,pass,nm)
  loop
    uid := gen_random_uuid();
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,
      created_at,updated_at,confirmation_token,email_change,email_change_token_new,recovery_token)
    values('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',u.email,
      extensions.crypt(u.pass,extensions.gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}',
      jsonb_build_object('name',u.nm),now(),now(),'','','','');
    insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
    values(gen_random_uuid(),uid,uid::text,jsonb_build_object('sub',uid::text,'email',u.email),'email',now(),now(),now());
    if u.email='k.belmin@pobjeda.com' then
      insert into user_plants select uid,id from plants where name in ('12','12A','24A');
    end if;
  end loop;
end $$;
