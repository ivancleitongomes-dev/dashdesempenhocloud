-- =====================================================================
-- Dashboard de desempenho do atendimento
-- Etapa (a): schema
--
-- Tudo fica no schema "atendimento", que NÃO é exposto pela API do
-- Supabase. As tabelas têm RLS ligada e nenhum acesso para anon ou
-- authenticated: só o service_role (Edge Function) lê e escreve.
-- A gravação passa pela função public.atd_ingerir, que faz upsert por id
-- e só pode ser chamada com a service_role key.
-- As funções de métricas (leitura pública) entram na etapa (c).
-- =====================================================================

create schema if not exists atendimento;
revoke all on schema atendimento from public;
revoke all on schema atendimento from anon, authenticated;
grant usage on schema atendimento to service_role;

-- ---------------------------------------------------------------------
-- Conversões dos formatos da API do CloudChat
-- ---------------------------------------------------------------------

-- Datas: a API devolve epoch em segundos; os webhooks podem mandar ISO 8601.
create or replace function atendimento.ts(v jsonb)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $f$
declare
  s text := v #>> '{}';
  n numeric;
begin
  if s is null or s = '' then
    return null;
  end if;
  if s ~ '^\d+(\.\d+)?$' then
    n := s::numeric;
    if n = 0 then
      return null;
    end if;
    if n > 100000000000 then          -- veio em milissegundos
      n := n / 1000;
    end if;
    return to_timestamp(n::double precision);
  end if;
  return s::timestamptz;
end
$f$;

-- Tipo de mensagem: a API devolve 0..3; os webhooks mandam o nome.
create or replace function atendimento.tipo_msg(v jsonb)
returns text
language sql
immutable
set search_path = ''
as $f$
  select case v #>> '{}'
    when '0' then 'incoming'
    when '1' then 'outgoing'
    when '2' then 'activity'
    when '3' then 'template'
    else v #>> '{}'
  end
$f$;

-- ---------------------------------------------------------------------
-- Parâmetros das regras (mudam sem alterar código)
-- ---------------------------------------------------------------------
create table if not exists atendimento.parametros (
  chave     text primary key,
  valor     text not null,
  descricao text
);

insert into atendimento.parametros (chave, valor, descricao) values
  ('claudia_agente_id',          '516', 'Id do usuário da ClaudIA no CloudChat'),
  ('tag_sem_contexto',           'sem-contexto_agilean_dúvida_n1', 'Tag tirada do ARR bruto na versão "sem a tag" (existe desde 09/10/2026)'),
  ('fuso',                       'America/Sao_Paulo', 'Fuso do horário comercial'),
  ('texto_aviso_inatividade',    'Caso não responda nos próximos minutos', 'Trecho fixo do aviso automático de inatividade da ClaudIA'),
  ('texto_encerramento',         'Estamos encerrando este contato agora', 'Trecho fixo da mensagem automática de encerramento da ClaudIA'),
  ('pergunta_cortesia',          'Posso auxiliar em algo mais?', 'Pergunta tratada como afirmação na regra de não resolvida'),
  ('feriados_abrangencia',       'nacional,CE,Fortaleza', 'Feriados que param o relógio do horário comercial'),
  ('pontos_facultativos_contam', 'sim', 'Se Carnaval e Corpus Christi param o relógio (sim/nao)')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- Horário comercial e feriados
-- ---------------------------------------------------------------------
create table if not exists atendimento.horario_comercial (
  dia_semana smallint primary key check (dia_semana between 0 and 6),  -- 0 = domingo
  inicio     time not null,
  fim        time not null,
  check (fim > inicio)
);

-- Padrão provisório: segunda a sexta, 08:00 às 18:00 (confirmar)
insert into atendimento.horario_comercial (dia_semana, inicio, fim) values
  (1, '08:00', '18:00'), (2, '08:00', '18:00'), (3, '08:00', '18:00'),
  (4, '08:00', '18:00'), (5, '08:00', '18:00')
on conflict (dia_semana) do nothing;

create table if not exists atendimento.feriados (
  data              date not null,
  nome              text not null,
  abrangencia       text not null check (abrangencia in ('nacional', 'CE', 'Fortaleza')),
  ponto_facultativo boolean not null default false,
  primary key (data, abrangencia)
);

-- Domingo de Páscoa (algoritmo de Meeus/Jones/Butcher)
create or replace function atendimento.pascoa(ano int)
returns date
language plpgsql
immutable
set search_path = ''
as $f$
declare
  a int; b int; c int; d int; e int; f int; g int;
  h int; i int; k int; l int; m int; mes int; dia int;
begin
  a := ano % 19;
  b := ano / 100;
  c := ano % 100;
  d := b / 4;
  e := b % 4;
  f := (b + 8) / 25;
  g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30;
  i := c / 4;
  k := c % 4;
  l := (32 + 2 * e + 2 * i - h - k) % 7;
  m := (a + 11 * h + 22 * l) / 451;
  mes := (h + l - 7 * m + 114) / 31;
  dia := ((h + l - 7 * m + 114) % 31) + 1;
  return make_date(ano, mes, dia);
end
$f$;

-- Gera os feriados de um ano (idempotente)
create or replace function atendimento.gerar_feriados(p_ano int)
returns int
language plpgsql
set search_path = ''
as $f$
declare
  p date := atendimento.pascoa(p_ano);
  n int;
begin
  insert into atendimento.feriados (data, nome, abrangencia, ponto_facultativo) values
    (make_date(p_ano, 1, 1),   'Confraternização Universal', 'nacional', false),
    (p - 48,                   'Carnaval (segunda-feira)', 'nacional', true),
    (p - 47,                   'Carnaval (terça-feira)', 'nacional', true),
    (p - 2,                    'Sexta-feira Santa', 'nacional', false),
    (make_date(p_ano, 4, 21),  'Tiradentes', 'nacional', false),
    (make_date(p_ano, 5, 1),   'Dia do Trabalho', 'nacional', false),
    (p + 60,                   'Corpus Christi', 'nacional', true),
    (make_date(p_ano, 9, 7),   'Independência do Brasil', 'nacional', false),
    (make_date(p_ano, 10, 12), 'Nossa Senhora Aparecida', 'nacional', false),
    (make_date(p_ano, 11, 2),  'Finados', 'nacional', false),
    (make_date(p_ano, 11, 15), 'Proclamação da República', 'nacional', false),
    (make_date(p_ano, 11, 20), 'Dia Nacional de Zumbi e da Consciência Negra', 'nacional', false),
    (make_date(p_ano, 12, 25), 'Natal', 'nacional', false),
    (make_date(p_ano, 3, 19),  'São José', 'CE', false),
    (make_date(p_ano, 3, 25),  'Data Magna do Ceará', 'CE', false),
    (make_date(p_ano, 8, 15),  'Nossa Senhora da Assunção', 'Fortaleza', false)
  on conflict (data, abrangencia) do nothing;
  get diagnostics n = row_count;
  return n;
end
$f$;

select atendimento.gerar_feriados(y) from generate_series(2026, 2030) as y;

-- ---------------------------------------------------------------------
-- Dados vindos do CloudChat
-- ---------------------------------------------------------------------
create table if not exists atendimento.agentes (
  id              integer primary key,
  nome            text,
  papel           text,
  eh_ia           boolean not null default false,
  disponibilidade text,                       -- online | busy | offline
  raw             jsonb,
  atualizado_em   timestamptz not null default now()
);

create table if not exists atendimento.times (
  id            integer primary key,
  nome          text,
  atualizado_em timestamptz not null default now()
);

create table if not exists atendimento.conversas (
  id                         integer primary key,   -- número da conversa no CloudChat (o da URL)
  uuid                       uuid unique,
  inbox_id                   integer,
  status                     text,                  -- open | resolved | pending | snoozed
  prioridade                 text,
  assignee_id                integer,
  team_id                    integer,
  contato_id                 bigint,
  contato_nome               text,
  labels                     text[] not null default '{}',
  criada_em                  timestamptz,
  ultima_atividade_em        timestamptz,
  primeira_resposta_em       timestamptz,           -- first_reply_created_at da API
  aguardando_desde           timestamptz,           -- waiting_since da API
  raw                        jsonb,                 -- objeto completo da API, sem a lista de mensagens
  precisa_sync               boolean not null default false,
  sincronizada_em            timestamptz,
  mensagens_sincronizadas_em timestamptz
);

create index if not exists conversas_criada_em_idx   on atendimento.conversas (criada_em);
create index if not exists conversas_abertas_idx     on atendimento.conversas (assignee_id) where status <> 'resolved';
create index if not exists conversas_precisa_sync_idx on atendimento.conversas (id) where precisa_sync;
create index if not exists conversas_labels_idx      on atendimento.conversas using gin (labels);

create table if not exists atendimento.mensagens (
  id                 bigint primary key,
  conversa_id        integer not null references atendimento.conversas (id) on delete cascade,
  tipo               text not null,          -- incoming | outgoing | activity | template
  content_type       text,                   -- text | input_csat | ...
  privada            boolean not null default false,
  remetente_tipo     text,                   -- contact | user | agent_bot | null (atividade)
  remetente_id       bigint,
  conteudo           text,
  content_attributes jsonb,
  criada_em          timestamptz not null,
  recebida_em        timestamptz not null default now()
);

create index if not exists mensagens_conversa_idx on atendimento.mensagens (conversa_id, criada_em, id);

create table if not exists atendimento.csat (
  id          bigint primary key,
  conversa_id integer,
  message_id  bigint,
  nota        smallint check (nota between 1 and 5),
  comentario  text,
  agente_id   integer,                       -- assigned_agent da resposta
  criada_em   timestamptz,
  raw         jsonb
);

create index if not exists csat_conversa_idx  on atendimento.csat (conversa_id);
create index if not exists csat_criada_em_idx on atendimento.csat (criada_em);

-- ---------------------------------------------------------------------
-- Controle da sincronização
-- ---------------------------------------------------------------------
create table if not exists atendimento.sync_estado (
  chave         text primary key,              -- ex.: conversas_watermark, csat_watermark
  valor         timestamptz,
  atualizado_em timestamptz not null default now()
);

create table if not exists atendimento.sync_execucoes (
  id           bigint generated always as identity primary key,
  origem       text not null check (origem in ('cron', 'webhook', 'backfill', 'manual')),
  iniciada_em  timestamptz not null default now(),
  concluida_em timestamptz,
  conversas    int not null default 0,
  mensagens    int not null default 0,
  csat         int not null default 0,
  erro         text
);

-- ---------------------------------------------------------------------
-- Gravação: upsert de um lote vindo da Edge Function
--
-- p_lote = {
--   "agentes":   [objetos de /agents],
--   "times":     [objetos de /teams],
--   "conversas": [objetos de /conversations/{id} ou do webhook],
--   "mensagens": [objetos de /conversations/{id}/messages, com "_conversa_id"],
--   "csat":      [objetos de /csat_survey_responses],
--   "mensagens_completas": [ids de conversas cujo histórico veio inteiro]
-- }
-- ---------------------------------------------------------------------
create or replace function public.atd_ingerir(p_lote jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  v_claudia int := (select valor::int from atendimento.parametros where chave = 'claudia_agente_id');
  v_ag int := 0;
  v_times int := 0;
  v_conv int := 0;
  v_msg int := 0;
  v_csat int := 0;
begin
  -- agentes
  insert into atendimento.agentes as a (id, nome, papel, eh_ia, disponibilidade, raw, atualizado_em)
  select distinct on ((x->>'id')::int)
         (x->>'id')::int,
         coalesce(nullif(x->>'display_name', ''), nullif(x->>'available_name', ''), x->>'name'),
         x->>'role',
         coalesce((x->>'is_ai_agent')::boolean, false) or (x->>'id')::int = v_claudia,
         coalesce(x->>'availability_status', x->>'availability'),
         x,
         now()
  from jsonb_array_elements(coalesce(p_lote->'agentes', '[]'::jsonb)) as x
  where x ? 'id'
  order by (x->>'id')::int
  on conflict (id) do update set
    nome            = excluded.nome,
    papel           = excluded.papel,
    eh_ia           = excluded.eh_ia,
    disponibilidade = excluded.disponibilidade,
    raw             = excluded.raw,
    atualizado_em   = now();
  get diagnostics v_ag = row_count;

  -- times
  insert into atendimento.times as t (id, nome, atualizado_em)
  select distinct on ((x->>'id')::int) (x->>'id')::int, x->>'name', now()
  from jsonb_array_elements(coalesce(p_lote->'times', '[]'::jsonb)) as x
  where x ? 'id'
  order by (x->>'id')::int
  on conflict (id) do update set nome = excluded.nome, atualizado_em = now();
  get diagnostics v_times = row_count;

  -- conversas (um retrato mais antigo nunca sobrescreve um mais novo)
  insert into atendimento.conversas as c (
    id, uuid, inbox_id, status, prioridade, assignee_id, team_id, contato_id, contato_nome,
    labels, criada_em, ultima_atividade_em, primeira_resposta_em, aguardando_desde,
    raw, precisa_sync, sincronizada_em)
  select distinct on ((x->>'id')::int)
         (x->>'id')::int,
         nullif(x->>'uuid', '')::uuid,
         nullif(x->>'inbox_id', '')::int,
         x->>'status',
         x->>'priority',
         coalesce(nullif(x#>>'{meta,assignee,id}', '')::int, nullif(x->>'assignee_id', '')::int),
         coalesce(nullif(x#>>'{meta,team,id}', '')::int, nullif(x->>'team_id', '')::int),
         coalesce(nullif(x#>>'{meta,sender,id}', '')::bigint, nullif(x#>>'{contact,id}', '')::bigint),
         coalesce(x#>>'{meta,sender,name}', x#>>'{contact,name}'),
         coalesce(array(select jsonb_array_elements_text(x->'labels')), '{}'::text[]),
         atendimento.ts(x->'created_at'),
         atendimento.ts(coalesce(x->'last_activity_at', x->'timestamp')),
         atendimento.ts(x->'first_reply_created_at'),
         atendimento.ts(x->'waiting_since'),
         x - 'messages',
         false,
         now()
  from jsonb_array_elements(coalesce(p_lote->'conversas', '[]'::jsonb)) as x
  where x ? 'id'
  order by (x->>'id')::int, atendimento.ts(coalesce(x->'last_activity_at', x->'timestamp')) desc nulls last
  on conflict (id) do update set
    uuid                 = coalesce(excluded.uuid, c.uuid),
    inbox_id             = coalesce(excluded.inbox_id, c.inbox_id),
    status               = coalesce(excluded.status, c.status),
    prioridade           = case when excluded.raw ? 'priority' then excluded.prioridade else c.prioridade end,
    assignee_id          = case when excluded.raw ? 'meta' or excluded.raw ? 'assignee_id' then excluded.assignee_id else c.assignee_id end,
    team_id              = case when excluded.raw ? 'meta' or excluded.raw ? 'team_id' then excluded.team_id else c.team_id end,
    contato_id           = coalesce(excluded.contato_id, c.contato_id),
    contato_nome         = coalesce(excluded.contato_nome, c.contato_nome),
    labels               = case when excluded.raw ? 'labels' then excluded.labels else c.labels end,
    criada_em            = coalesce(excluded.criada_em, c.criada_em),
    ultima_atividade_em  = greatest(excluded.ultima_atividade_em, c.ultima_atividade_em),
    primeira_resposta_em = coalesce(excluded.primeira_resposta_em, c.primeira_resposta_em),
    aguardando_desde     = case when excluded.raw ? 'waiting_since' then excluded.aguardando_desde else c.aguardando_desde end,
    raw                  = excluded.raw,
    precisa_sync         = false,
    sincronizada_em      = now()
  where c.ultima_atividade_em is null
     or excluded.ultima_atividade_em is null
     or excluded.ultima_atividade_em >= c.ultima_atividade_em;
  get diagnostics v_conv = row_count;

  -- conversa citada por mensagem e ainda desconhecida: cria um esboço que o cron completa
  insert into atendimento.conversas (id, precisa_sync)
  select distinct coalesce(nullif(x->>'_conversa_id', '')::int, nullif(x->>'conversation_id', '')::int), true
  from jsonb_array_elements(coalesce(p_lote->'mensagens', '[]'::jsonb)) as x
  where coalesce(nullif(x->>'_conversa_id', ''), nullif(x->>'conversation_id', '')) is not null
  on conflict (id) do nothing;

  -- mensagens
  insert into atendimento.mensagens as m (
    id, conversa_id, tipo, content_type, privada, remetente_tipo, remetente_id,
    conteudo, content_attributes, criada_em)
  select distinct on ((x->>'id')::bigint)
         (x->>'id')::bigint,
         coalesce(nullif(x->>'_conversa_id', '')::int, nullif(x->>'conversation_id', '')::int),
         coalesce(atendimento.tipo_msg(x->'message_type'), 'desconhecido'),
         x->>'content_type',
         coalesce((x->>'private')::boolean, false),
         lower(coalesce(x#>>'{sender,type}', x->>'sender_type')),
         coalesce(nullif(x#>>'{sender,id}', '')::bigint, nullif(x->>'sender_id', '')::bigint),
         x->>'content',
         x->'content_attributes',
         coalesce(atendimento.ts(x->'created_at'), now())
  from jsonb_array_elements(coalesce(p_lote->'mensagens', '[]'::jsonb)) as x
  where x ? 'id'
    and coalesce(nullif(x->>'_conversa_id', ''), nullif(x->>'conversation_id', '')) is not null
  order by (x->>'id')::bigint
  on conflict (id) do update set
    tipo               = excluded.tipo,
    content_type       = excluded.content_type,
    privada            = excluded.privada,
    conteudo           = excluded.conteudo,
    content_attributes = excluded.content_attributes;
  get diagnostics v_msg = row_count;

  update atendimento.conversas
     set mensagens_sincronizadas_em = now()
   where id in (
     select (jsonb_array_elements_text(coalesce(p_lote->'mensagens_completas', '[]'::jsonb)))::int
   );

  -- CSAT (a conversa sai pela mensagem da pesquisa, que tem id único no CloudChat)
  insert into atendimento.csat as s (id, conversa_id, message_id, nota, comentario, agente_id, criada_em, raw)
  select distinct on ((x->>'id')::bigint)
         (x->>'id')::bigint,
         coalesce(
           (select mm.conversa_id from atendimento.mensagens mm where mm.id = nullif(x->>'message_id', '')::bigint),
           nullif(x->>'conversation_id', '')::int),
         nullif(x->>'message_id', '')::bigint,
         nullif(x->>'rating', '')::smallint,
         nullif(x->>'feedback_message', ''),
         coalesce(nullif(x#>>'{assigned_agent,id}', '')::int, nullif(x->>'assigned_agent_id', '')::int),
         atendimento.ts(x->'created_at'),
         x
  from jsonb_array_elements(coalesce(p_lote->'csat', '[]'::jsonb)) as x
  where x ? 'id'
  order by (x->>'id')::bigint
  on conflict (id) do update set
    conversa_id = coalesce(excluded.conversa_id, s.conversa_id),
    nota        = excluded.nota,
    comentario  = excluded.comentario,
    agente_id   = coalesce(excluded.agente_id, s.agente_id),
    raw         = excluded.raw;
  get diagnostics v_csat = row_count;

  return jsonb_build_object(
    'agentes', v_ag, 'times', v_times, 'conversas', v_conv,
    'mensagens', v_msg, 'csat', v_csat);
end
$f$;

-- ---------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------
alter table atendimento.parametros        enable row level security;
alter table atendimento.horario_comercial enable row level security;
alter table atendimento.feriados          enable row level security;
alter table atendimento.agentes           enable row level security;
alter table atendimento.times             enable row level security;
alter table atendimento.conversas         enable row level security;
alter table atendimento.mensagens         enable row level security;
alter table atendimento.csat              enable row level security;
alter table atendimento.sync_estado       enable row level security;
alter table atendimento.sync_execucoes    enable row level security;
-- Sem políticas: anon e authenticated não leem nem escrevem nada aqui.

revoke all on all tables    in schema atendimento from public, anon, authenticated;
revoke all on all sequences in schema atendimento from public, anon, authenticated;
revoke all on all functions in schema atendimento from public, anon, authenticated;
grant all     on all tables    in schema atendimento to service_role;
grant all     on all sequences in schema atendimento to service_role;
grant execute on all functions in schema atendimento to service_role;

alter default privileges in schema atendimento revoke all on tables    from public, anon, authenticated;
alter default privileges in schema atendimento revoke all on sequences from public, anon, authenticated;
alter default privileges in schema atendimento revoke all on functions from public, anon, authenticated;
alter default privileges in schema atendimento grant all on tables    to service_role;
alter default privileges in schema atendimento grant all on sequences to service_role;

revoke all on function public.atd_ingerir(jsonb) from public, anon, authenticated;
grant execute on function public.atd_ingerir(jsonb) to service_role;
