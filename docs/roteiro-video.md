# Roteiro do vídeo — Trabalho 1 (LarCerto)

Rascunho para o aluno gravar (REQ17–REQ21). O agente não grava, não publica e não envia nada.

- **Duração-alvo:** 6 min (REQ21: 5–7 min, sem acelerar)
- **Rosto** visível na explicação (REQ19) e **voz** nítida (REQ20)
- **Fontes grandes** no terminal e no navegador (REQ18): zoom 150% e terminal com fonte 18+
- Antes de gravar: lab ligado (`./project/lab.sh start`), nuvem montada e a CA importada no Firefox

## Cenas

| # | Cena | Duracao (s) | O que mostrar | REQ |
|---|------|------------:|---------------|-----|
| 1 | Abertura (rosto) | 30 | Nome, disciplina, a LarCerto: aluguel verificado para estudantes em Guarapuava (ODS 11) | REQ01, REQ19 |
| 2 | Topologia | 40 | Diagrama: host → OpenStack (Kolla AIO) → projeto `larcerto` → VMs `dns`, `ca`, `db`, `web`; rede `public` 172.24.4.0/24 e `larcerto-net` 10.11.12.0/24 | REQ09 |
| 3 | DevOps: nuvem | 50 | `./project/lab.sh status`; Horizon em `cloud.larcerto.com.br` logado como `devops1`: projeto, rede, router, VMs | REQ12, REQ13 |
| 4 | DevOps: recriar a infra | 70 | `terraform destroy` / `terraform apply` (cortar a espera com cronômetro na tela, sem acelerar a fala) | REQ14, REQ15, REQ25 |
| 5 | DevOps: configurar | 60 | `ansible-playbook site.yml`: dns → ca → db → web | REQ10, REQ11, REQ16, REQ25 |
| 6 | DNS e certificados | 40 | `dig @<dns> www.larcerto.com.br`; `openssl verify` do certificado; CA no Firefox | REQ10, REQ11 |
| 7 | Cliente: usar a app | 60 | `https://larcerto.com.br` com cadeado; listar, filtrar, anunciar, editar e excluir um imóvel | REQ02, REQ04, REQ16 |
| 8 | Cliente: HTTP → HTTPS | 20 | `http://larcerto.com.br` redireciona para HTTPS | REQ16 |
| 9 | Encerramento (rosto) | 30 | O que foi feito, o diferencial (recriação automática) e agradecimento | REQ19 |

Total: 400 s ≈ 6 min 40 s.

## Publicação (aluno)

- YouTube **não listado** ou Drive, com permissão para `hermanopereira@professores.utfpr.edu.br` (REQ22)
- Testar o link numa aba anônima: sem encurtador e sem pedido de permissão (REQ23)
- Enviar no Moodle e conferir que **não** ficou como rascunho (REQ24)
