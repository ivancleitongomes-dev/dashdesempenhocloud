# Dashboard de desempenho do atendimento

Indicadores da equipe de atendimento e da ClaudIA, com dados do CloudChat.

## Como funciona

- **Supabase**: guarda as conversas do CloudChat e calcula os indicadores.
  - `supabase/migrations/`: estrutura do banco (tabelas, regras e permissões).
  - `supabase/functions/`: Edge Function que busca os dados na API do CloudChat (etapa b).
- **Vercel**: publica a página do dashboard (etapa e).

## Segurança

- Nenhuma chave secreta fica neste repositório.
- O token do CloudChat e a service_role key ficam só nos Secrets do Supabase.
- A página usa apenas a chave pública (anon), que só enxerga os indicadores.

## Etapas

- [x] (a) Schema SQL
- [ ] (b) Edge Function + cron + webhook
- [ ] (c) Funções de métricas
- [ ] (d) Página do dashboard
- [ ] (e) Deploy no Vercel
