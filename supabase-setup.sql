-- =====================================================================
--  ร้านอะไหล่ Fortuner 2022 : ตั้งค่าฐานข้อมูล Supabase
--  วิธีใช้: Supabase → SQL Editor → New query → วางทั้งไฟล์ → กด Run
--  ★ แก้บรรทัดที่มี YOUR_EMAIL ให้เป็นอีเมลเจ้าของร้านก่อนกด Run ★
-- =====================================================================

-- 1) เจ้าของร้าน (มีได้คนเดียวหรือหลายคน ตามอีเมลในตารางนี้)
create table if not exists public.admins (email text primary key);
alter table public.admins enable row level security;   -- ไม่มี policy = ไม่มีใครอ่าน/แก้ผ่านเว็บได้
insert into public.admins (email) values (lower('auttavut.mana@gmail.com')) on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where a.email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- 2) ตารางอะไหล่
create table if not exists public.parts (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  cat        text not null check (cat in ('ext','engine','chassis')),
  name       text not null,
  pn         text not null default '',
  price      integer not null default 0 check (price >= 0),
  stock      integer not null default 0 check (stock >= 0),
  by_grade   jsonb not null default '{}'::jsonb,
  engines    text[] not null default '{}',
  eng_pn     boolean not null default false,
  note       text not null default '',
  icon       text not null default 'box',
  pos        double precision[],
  n          double precision[],
  created_at timestamptz not null default now()
);
alter table public.parts enable row level security;
drop policy if exists "parts: everyone reads" on public.parts;
create policy "parts: everyone reads" on public.parts for select to anon, authenticated using (true);
drop policy if exists "parts: owner writes" on public.parts;
create policy "parts: owner writes" on public.parts for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 3) ข้อมูลร้าน (แถวเดียว)
create table if not exists public.settings (
  id        int primary key default 1 check (id = 1),
  name      text not null default 'อะไหล่ Fortuner 2022',
  phone     text not null default '',
  line      text not null default '',
  promptpay text not null default ''
);
insert into public.settings (id) values (1) on conflict do nothing;
alter table public.settings enable row level security;
drop policy if exists "settings: everyone reads" on public.settings;
create policy "settings: everyone reads" on public.settings for select to anon, authenticated using (true);
drop policy if exists "settings: owner updates" on public.settings;
create policy "settings: owner updates" on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- 4) ออเดอร์ (ลูกค้าสร้างผ่านฟังก์ชัน place_order เท่านั้น อ่านได้เฉพาะเจ้าของร้าน)
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  created_at    timestamptz not null default now(),
  status        text not null default 'new' check (status in ('new','confirmed','shipped','cancelled')),
  stock_applied boolean not null default false,
  items         jsonb not null,
  total         integer not null,
  customer      jsonb not null,
  note          text not null default '',
  grade         text,
  engine        text
);
alter table public.orders enable row level security;
drop policy if exists "orders: owner reads" on public.orders;
create policy "orders: owner reads" on public.orders for select to authenticated using (public.is_admin());
drop policy if exists "orders: owner deletes" on public.orders;
create policy "orders: owner deletes" on public.orders for delete to authenticated using (public.is_admin());

-- 5) ลูกค้าสั่งซื้อ: ราคาคำนวณจากฐานข้อมูลเสมอ ลูกค้าแก้ราคาเองไม่ได้
create or replace function public.place_order(p_items jsonb, p_customer jsonb, p_note text, p_grade text, p_engine text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; pr public.parts; q int; unit int; v_total int := 0; out_items jsonb := '[]'::jsonb; v_code text;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then raise exception 'invalid items'; end if;
  if p_grade not in ('std','leg','grs') or p_engine not in ('2.4','2.8') then raise exception 'invalid vehicle'; end if;
  if length(trim(coalesce(p_customer->>'name',''))) < 1 or length(regexp_replace(coalesce(p_customer->>'phone',''), '\D', '', 'g')) < 9 then raise exception 'invalid customer'; end if;
  if (select count(*) from public.orders where created_at > now() - interval '1 minute') > 30 then raise exception 'busy'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'q')::int;
    if q is null or q < 1 or q > 20 then raise exception 'invalid qty'; end if;
    select * into pr from public.parts where id = (it->>'part_id')::uuid;
    if not found then raise exception 'part not found'; end if;
    if cardinality(pr.engines) > 0 and not (p_engine = any(pr.engines)) then raise exception 'part does not fit'; end if;
    unit := coalesce((pr.by_grade->>p_grade)::int, pr.price);
    v_total := v_total + unit * q;
    out_items := out_items || jsonb_build_object(
      'part_id', pr.id, 'code', pr.code, 'name', pr.name, 'price', unit, 'q', q,
      'pn', pr.pn || case when pr.by_grade ? p_grade then '-' || upper(p_grade) else '' end
                  || case when pr.eng_pn then '-' || replace(p_engine, '.', '') else '' end);
  end loop;

  v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  insert into public.orders (code, items, total, customer, note, grade, engine)
  values (v_code, out_items, v_total,
    jsonb_build_object(
      'name', left(trim(p_customer->>'name'), 100),
      'phone', left(trim(p_customer->>'phone'), 30),
      'method', case when p_customer->>'method' = 'pickup' then 'pickup' else 'ship' end,
      'address', left(coalesce(p_customer->>'address', ''), 400)),
    left(coalesce(p_note, ''), 500), p_grade, p_engine);
  return jsonb_build_object('code', v_code, 'total', v_total, 'items', out_items);
end; $$;

-- 6) ลูกค้าดูสถานะออเดอร์ของตัวเองด้วยรหัสออเดอร์
create or replace function public.order_status(p_codes text[])
returns table (code text, status text, total int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.code, o.status, o.total, o.created_at from public.orders o
  where o.code = any (p_codes[1:20]);
$$;

-- 7) เจ้าของร้านเปลี่ยนสถานะ: ยืนยัน/ส่ง = ตัดสต็อก, ยกเลิก = คืนสต็อก
create or replace function public.set_order_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders; it jsonb; sign int := 0;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('new','confirmed','shipped','cancelled') then raise exception 'invalid status'; end if;
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'not found'; end if;
  if p_status in ('confirmed','shipped') and not o.stock_applied then sign := -1; o.stock_applied := true;
  elsif p_status in ('cancelled','new') and o.stock_applied then sign := 1; o.stock_applied := false;
  end if;
  if sign <> 0 then
    for it in select * from jsonb_array_elements(o.items) loop
      update public.parts set stock = greatest(0, stock + sign * (it->>'q')::int) where id = (it->>'part_id')::uuid;
    end loop;
  end if;
  update public.orders set status = p_status, stock_applied = o.stock_applied where id = p_id;
end; $$;

revoke all on function public.set_order_status(uuid, text) from anon;
grant execute on function public.place_order(jsonb, jsonb, text, text, text) to anon, authenticated;
grant execute on function public.order_status(text[]) to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.set_order_status(uuid, text) to authenticated;

-- 8) อะไหล่ตัวอย่าง 23 รายการ (ลบหรือแก้ได้ในหลังร้าน)
insert into public.parts (code,cat,name,pn,price,stock,by_grade,engines,eng_pn,note,icon,pos,n) values
  ('E1','ext','ไฟหน้า LED ข้างซ้าย','FT22-HL-L',18500,4,'{"leg": 24900}'::jsonb,'{}'::text[],false,'Legender ใช้โคมทรงบาง แยกรหัสกับรุ่นมาตรฐาน','lamp',array[-2.299,0.891,0.6]::float8[],array[-1,0,0.4]::float8[]),
  ('E2','ext','กระจังหน้า','FT22-GR',9800,2,'{"leg": 14500, "grs": 12800}'::jsonb,'{}'::text[],false,'ลายกระจังต่างกันในแต่ละรุ่นย่อย','grille',array[-2.376,0.748,0]::float8[],array[-1,0,0]::float8[]),
  ('E3','ext','กันชนหน้า (ยังไม่ทำสี)','FT22-BF',7900,0,'{}'::jsonb,'{}'::text[],false,'','bumper',array[-2.321,0.506,0.45]::float8[],array[-1,0,0.2]::float8[]),
  ('E4','ext','กระจกมองข้าง ปรับและพับไฟฟ้า','FT22-MR-R',6200,6,'{}'::jsonb,'{}'::text[],false,'','mirror',array[-0.814,1.144,1.0]::float8[],array[0,0.25,1]::float8[]),
  ('E5','ext','มือจับประตูด้านนอก หน้าขวา','FT22-DH-FR',1450,12,'{}'::jsonb,'{}'::text[],false,'','handle',array[0.0,0.99,0.9]::float8[],array[0,0,1]::float8[]),
  ('E6','ext','ไฟท้าย LED ข้างขวา','FT22-TL-R',8900,3,'{}'::jsonb,'{}'::text[],false,'','lamp',array[2.365,0.946,0.72]::float8[],array[1,0,0.4]::float8[]),
  ('E7','ext','ราวหลังคา','FT22-RR',4500,5,'{}'::jsonb,'{}'::text[],false,'','rail',array[0.77,1.804,0.58]::float8[],array[0,1,0.2]::float8[]),
  ('E8','ext','ใบปัดน้ำฝนหน้า 26"/16" (คู่)','FT22-WB',690,30,'{}'::jsonb,'{}'::text[],false,'','wiper',array[-0.935,1.1,0.3]::float8[],array[-0.7,1,0]::float8[]),
  ('G1','engine','ไส้กรองอากาศ','FT22-AF',650,24,'{}'::jsonb,'{}'::text[],false,'','filter',array[-1.496,0.99,0.35]::float8[],null),
  ('G2','engine','ไส้กรองน้ำมันเครื่อง','FT22-OF',280,40,'{}'::jsonb,'{}'::text[],false,'','filter',array[-1.65,0.561,-0.25]::float8[],null),
  ('G3','engine','แบตเตอรี่ 12V 80Ah','FT22-BT',4200,8,'{}'::jsonb,'{}'::text[],false,'','battery',array[-1.144,1.001,0.55]::float8[],null),
  ('G4','engine','หม้อน้ำ','FT22-RD',7800,1,'{}'::jsonb,'{}'::text[],false,'','radiator',array[-2.222,0.77,0]::float8[],null),
  ('G5','engine','สายพานหน้าเครื่อง','FT22-BL',1250,10,'{}'::jsonb,'{}'::text[],true,'','belt',array[-1.98,0.704,0.45]::float8[],null),
  ('G6','engine','ไส้กรองโซล่า','FT22-FF',850,15,'{}'::jsonb,'{}'::text[],false,'','filter',array[-1.254,0.726,-0.5]::float8[],null),
  ('G7','engine','ชุดคลัตช์ (เฉพาะเกียร์ธรรมดา)','FT22-CL',9500,2,'{}'::jsonb,array['2.4']::text[],false,'มีเฉพาะเครื่อง 2.4 เกียร์ธรรมดา','clutch',array[-0.55,0.561,0]::float8[],null),
  ('C1','chassis','จานเบรกหน้า (ข้างละ)','FT22-DR-F',2900,9,'{}'::jsonb,'{}'::text[],false,'','disc',array[-1.485,0.374,0.66]::float8[],null),
  ('C2','chassis','ผ้าเบรกหน้า (ชุด)','FT22-BP-F',1850,20,'{}'::jsonb,'{}'::text[],false,'','pad',array[-1.276,0.539,0.64]::float8[],null),
  ('C3','chassis','โช้คอัพหน้า (ข้างละ)','FT22-SA-F',3600,6,'{}'::jsonb,'{}'::text[],false,'','shock',array[-1.529,0.737,0.58]::float8[],null),
  ('C4','chassis','โช้คอัพหลัง (ข้างละ)','FT22-SA-R',3100,6,'{}'::jsonb,'{}'::text[],false,'','shock',array[1.595,0.737,0.58]::float8[],null),
  ('C5','chassis','ยาง 265/60R18 (เส้น)','FT22-TY',5400,16,'{"grs": 6900}'::jsonb,'{}'::text[],false,'GR Sport ใช้ยาง 265/55R20','tyre',array[1.485,0.088,0.9]::float8[],array[0,0,1]::float8[]),
  ('C6','chassis','ผ้าเบรกหลัง (ชุด)','FT22-BP-R',1650,0,'{}'::jsonb,'{}'::text[],false,'','pad',array[1.694,0.539,0.64]::float8[],null),
  ('C7','chassis','ลูกหมากปีกนกล่าง','FT22-BJ',1200,3,'{}'::jsonb,'{}'::text[],false,'','joint',array[-1.716,0.231,0.5]::float8[],null),
  ('C8','chassis','เพลากลาง (4x4)','FT22-PS',12500,1,'{}'::jsonb,array['2.8']::text[],false,'ระบบขับเคลื่อน 4 ล้อ มากับเครื่อง 2.8','shaft',array[0.0,0.22,0]::float8[],null)
on conflict (code) do nothing;
