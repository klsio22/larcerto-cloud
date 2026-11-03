# Enunciado — Trabalho 1 (e base do Substitutivo)

Fonte: Moodle Computação em Nuvem (TSI36C-EAD) — Prof. Hermano Pereira.

- **Trabalho 1:** [assign/view.php?id=2138855](https://moodle.utfpr.edu.br/mod/assign/view.php?id=2138855) — até **10 pontos**
- **Substitutivo:** [assign/view.php?id=2138858](https://moodle.utfpr.edu.br/mod/assign/view.php?id=2138858) — mesmos REQs + **REQ25** (automação)

**Objetivo:** planejar, construir e gerenciar um projeto de nuvem **local-privada** (OpenStack) para hospedar uma aplicação web CRUD; entregar **vídeo 5–7 min** (rosto + voz).

Videoaulas base: módulos **06–10** da disciplina.

---

## Passo I — Personalização da aplicação CRUD

| Req | Descrição |
|-----|-----------|
| REQ01 | Nome fictício da empresa (criativo, evitar repetidos) |
| REQ02 | Logotipo em todas as páginas |
| REQ03 | Domínio DNS (ex.: `empresatal.com.br`) |
| REQ04 | Exclusivamente CRUD, sem módulos extras |
| REQ05 | Uma única tabela, 3 a 10 campos |
| REQ06 | Foco PHP; outras langs ok se frontend HTML/CSS |
| REQ07 | Frameworks só com consulta prévia ao professor |
| REQ08 | BD MySQL/MariaDB (ou acessível pela rede); sem SQLite/arquivo texto |

## Passo II — Topologia

| Req | Descrição |
|-----|-----------|
| REQ09 | Definir topologia conforme hardware. Sugestões: mínima (1 cliente + 1 servidor OpenStack com 1 VM web/db); ideal (+ DNS/CA); completa (VM por serviço) |

## Passo III — Ambiente

| Req | Descrição |
|-----|-----------|
| REQ10 | Servidor DNS para `*.empresatal.com.br` |
| REQ11 | CA + certificados para `*.empresatal.com.br` |
| REQ12 | Subir nuvem privada, FQDN (ex.: `cloud.empresatal.com.br`), certificados opcionais |

## Passo IV — Implantação

| Req | Descrição |
|-----|-----------|
| REQ13 | Projeto na nuvem privada |
| REQ14 | VM para aplicação web |
| REQ15 | VM para banco de dados |
| REQ16 | Implantar app, integrar BD, HTTP/HTTPS |

## Passo V — Demonstração

| Req | Descrição |
|-----|-----------|
| REQ17 | Cenário DevOps preparando ambiente + cliente usando app |
| REQ18 | Gravação nítida (fontes grandes) |

## Passo VI — Vídeo

| Req | Descrição |
|-----|-----------|
| REQ19 | Rosto na explicação |
| REQ20 | Voz nítida |
| REQ21 | 5–7 minutos; não acelerar |

## Passo VII — Publicação

| Req | Descrição |
|-----|-----------|
| REQ22 | YouTube (não listado) ou Drive; permissão a `hermanopereira@professores.utfpr.edu.br` |
| REQ23 | Sem links corrompidos/encurtados/sem permissão |
| REQ24 | Postar completo no Moodle (não rascunho) |

## Avaliação

CRIT01 requisitos · CRIT02 originalidade · CRIT03 competência · CRIT04 diferencial · **10 pontos**.

## Trabalho Substitutivo — REQ25

Automatizar implantação com **Terraform** (infra) **ou** **Ansible** (deploy). Outras nuvens só com acordo prévio com o professor.
