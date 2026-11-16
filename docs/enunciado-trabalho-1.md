# Enunciado — Trabalho 1 (e base do Substitutivo)

Fonte: Moodle Computação em Nuvem (TSI36C-EAD) — Prof. Hermano Pereira.

- **Trabalho 1 (único):** [assign/view.php?id=2138855](https://moodle.utfpr.edu.br/mod/assign/view.php?id=2138855) — até **10 pontos**; entrega prorrogada para **12/Nov**
- **Substitutivo:** [assign/view.php?id=2138858](https://moodle.utfpr.edu.br/mod/assign/view.php?id=2138858) — mesmos REQs + **REQ25** (automação)

**Objetivo:** planejar, construir e gerenciar um projeto de nuvem **local-privada** (OpenStack) para hospedar uma aplicação web CRUD; entregar **vídeo 5–7 min** (rosto + voz).

Videoaulas base: módulos **06–10** da disciplina.

---

## Passo I — Personalização da aplicação CRUD

Partir de uma aplicação CRUD da internet, respeitando os termos e direitos autorais do criador, e personalizá-la.

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
| REQ09 | Definir topologia conforme hardware. Sugestões: mínima (1 cliente + 1 servidor OpenStack com 1 VM web/db); ideal (1 cliente + 1 servidor DNS/CA + 1 servidor OpenStack com VM web e VM db); completa (VM dedicada por serviço) |

## Passo III — Ambiente

| Req | Descrição |
|-----|-----------|
| REQ10 | Servidor DNS para `*.empresatal.com.br` |
| REQ11 | CA + certificados válidos para `*.empresatal.com.br` |
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

Dica: gravar o cenário sem áudio e depois acrescentar a narração e o rosto na edição.

## Passo VI — Vídeo

| Req | Descrição |
|-----|-----------|
| REQ19 | Rosto na explicação |
| REQ20 | Voz nítida |
| REQ21 | 5–7 minutos; não acelerar |

Dica: gravar pelo Google Meet da UTFPR e salvar no Google Drive.

## Passo VII — Publicação

| Req | Descrição |
|-----|-----------|
| REQ22 | YouTube (não listado) ou Drive; permissão a `hermanopereira@professores.utfpr.edu.br` |
| REQ23 | Sem links corrompidos, incompletos, encurtados, sem permissão ou de pastas: **o trabalho é zerado**; testar o link antes |
| REQ24 | Postar completo no Moodle (não rascunho) |

Dica: mostrar as configurações importantes, explicar o cenário e demonstrar os comandos em execução.

## Avaliação

CRIT01 atendimento integral aos requisitos · CRIT02 originalidade (feito pelo aluno e funcionando) · CRIT03 competência (mostrar que entendeu o que fez) · **10 pontos**.

## Orientações do professor

- Ler o enunciado com atenção: trabalho bom perde pontos por requisito não atendido
- Rosto e voz nítida comprovam autoria e entendimento
- Apresentar o projeto, sem dar aula de DNS, web ou MySQL: como a app foi hospedada, ferramentas e configurações importantes
- Seguir os requisitos como roteiro é uma boa estratégia (não obrigatória)
- Ser conciso e direto

## Texto original do Trabalho 1 (Moodle)

> Entrega prorrogada para 12/Nov.
>
> **Trabalho 1 (único) - Projeto de Nuvem para Aplicação Web**
>
> **Objetivo:** Demonstrar sua capacidade de planejar, construir e gerenciar um projeto de nuvem do zero (em nuvem local-privada) para hospedar uma aplicação web.
>
> **Enunciado:** Personalize uma aplicação web CRUD para uma empresa fictícia, crie um projeto em uma nuvem privada (na sua máquina local) e hospede a aplicação. O resultado final será a gravação de um vídeo explicando todo o processo, desde a criação da infraestrutura (redes, permissões, VMs) até a aplicação estar em funcionamento.
>
> **Passo I: Personalização da Aplicação Web CRUD**
>
> Encontre uma aplicação web CRUD na internet. Respeite os termos e direitos autorais do criador, mas personalize o projeto.
>
> - REQ01: Crie um nome fictício para a sua empresa, com criatividade para evitar nomes repetidos.
> - REQ02: Crie um logotipo. Ele deve aparecer em todas as páginas da aplicação.
> - REQ03: Escolha um domínio (DNS) para a empresa, ex.: empresatal.com.br.
> - REQ04: A aplicação deve ser exclusivamente CRUD, sem módulos extras.
> - REQ05: A aplicação deve ter uma única tabela, com 3 a 10 campos (colunas).
> - REQ06: Embora o trabalho tenha foco em PHP, outras linguagens são permitidas, desde que o frontend seja HTML/CSS para navegadores.
> - REQ07: Frameworks não são permitidos, a menos que haja consulta prévia com o professor.
> - REQ08: O banco de dados deve ser MySQL/MariaDB ou outro acessível pela rede (não são permitidos arquivos de texto ou SQLite).
>
> **Passo II: Planejamento da Topologia**
>
> Defina a topologia de servidores para a sua nuvem, considerando seus recursos disponíveis.
>
> - REQ09: Prepare sua topologia. Sugestões:
>   - Mínima: 1 cliente (navegador/SSH) e 1 servidor OpenStack (1 VM para web/db).
>   - Ideal: 1 cliente, 1 servidor para DNS e CA, e 1 servidor OpenStack (1 VM para web e 1 VM para db).
>   - Completa: Uma VM dedicada para cada serviço, se os recursos de hardware permitirem.
>
> **Passo III: Configuração do Ambiente**
>
> Com a topologia definida, configure o ambiente para receber a aplicação web.
>
> - REQ10: Configure um servidor DNS para *.empresatal.com.br.
> - REQ11: Crie uma autoridade certificadora e gere certificados válidos para *.empresatal.com.br.
> - REQ12: Suba sua nuvem privada, configure um FQDN (ex.: cloud.empresatal.com.br) e, opcionalmente, aplique certificados digitais.
>
> **Passo IV: Implantação da Aplicação**
>
> Com o ambiente pronto, é hora de implantar a aplicação.
>
> - REQ13: Crie um projeto na sua nuvem privada.
> - REQ14: Crie uma VM na nuvem para hospedar a aplicação web.
> - REQ15: Crie outra VM para hospedar o banco de dados.
> - REQ16: Implante a aplicação, integre-a com o banco de dados e libere o acesso via HTTP/HTTPS.
>
> **Passo V: Preparação para a Demonstração**
>
> Prepare um cenário claro para a gravação do seu vídeo.
>
> - REQ17: Pense no cenário do DevOps preparando o ambiente e do cliente usando a aplicação.
> - REQ18: Garanta uma gravação nítida. Aumente as fontes de editores, navegadores e terminais, se necessário.
>
> Dica: Grave a execução do cenário sem áudio e, em seguida, adicione a narração e o seu rosto na edição.
>
> **Passo VI: Gravação do Vídeo Explicativo**
>
> Grave a sua apresentação final.
>
> - REQ19: Grave seu rosto durante a explicação.
> - REQ20: Garanta que sua voz seja nítida.
> - REQ21: O vídeo deve ter entre 5 e 7 minutos. Não acelere a gravação.
>
> Dica: Utilize o Google Meet da UTFPR para gravar e salvar no Google Drive.
>
> **Passo VII: Publicação do Vídeo**
>
> Publique o seu vídeo final.
>
> - REQ22: Use um link do Youtube (não listado) ou do Google Drive. Conceda permissão de acesso para hermanopereira@professores.utfpr.edu.br.
> - REQ23: ATENÇÃO: Não envie links corrompidos, incompletos, encurtados, sem permissão ou de pastas. O trabalho será zerado. Verifique e teste o link antes do envio.
> - REQ24: Poste o trabalho completamente, não como rascunho no Moodle.
>
> Dica: Mostre as configurações importantes, explique o cenário e demonstre os comandos em execução.
>
> **Avaliação**
>
> Seu trabalho será avaliado com base nos seguintes critérios:
>
> - CRIT01: Atendimento integral aos requisitos do enunciado.
> - CRIT02: Originalidade. O trabalho foi desenvolvido por você e funciona conforme o esperado?
> - CRIT03: Competência. Você demonstrou ter compreendido o que foi feito.
>
> Pontuação: Totalizando 10 pontos.
>
> **Orientações do Professor**
>
> - Leitura do Enunciado: Leia o enunciado com atenção. Trabalhos de alta qualidade podem perder pontos por não atenderem a todos os requisitos.
> - Qualidade da Apresentação: O vídeo com seu rosto e sua voz nítida é essencial para comprovar a autoria e o entendimento do projeto.
> - Foco no Projeto: Apresente seu projeto. Não é necessário dar uma aula sobre conceitos como DNS, WEB ou MySQL. Mostre como você hospedou a aplicação e as ferramentas e configurações importantes que utilizou.
> - Estratégia de Apresentação: Uma boa estratégia é seguir os requisitos como um roteiro, mas sinta-se à vontade para desenvolver sua própria forma.
> - Seja Direto: Otimize sua apresentação para ser conciso e direto ao ponto. O importante é que o espectador entenda seu projeto.
> - Planejamento: Comece o trabalho com, no mínimo, um mês de antecedência para garantir a qualidade e evitar a correria.
>
> Bom trabalho!

## Trabalho Substitutivo — REQ25

Todos os passos e requisitos do Trabalho 1 (REQ01–REQ24), mais a automação da implantação.

| Req | Descrição |
|-----|-----------|
| REQ25 | Automatizar a implantação: **Terraform** (criar a infraestrutura) **ou** **Ansible** (automatizar a implantação) |

**Opcional:** outras ferramentas de nuvem além do OpenStack, por responsabilidade do aluno e só com discussão prévia com o professor. Exemplos do enunciado: Packstack, Microstack, Microcloud, **OpenStack Kolla AIO (all-in-one)**, CloudStack.

O vídeo documenta todo o processo, da criação da infraestrutura (redes, permissões, VMs) até a aplicação em pleno funcionamento.

### Texto original do Substitutivo (Moodle)

> **Trabalho Substitutivo - Projeto de Nuvem para Aplicação Web**
>
> **Objetivo:** Demonstrar sua capacidade de gerenciar um projeto de nuvem do zero (nuvem local-privada), adicionando uma camada de automação para a implantação da aplicação.
>
> **Enunciado:** Personalize uma aplicação web CRUD para uma empresa fictícia, crie um projeto em uma nuvem privada (na sua máquina local) e hospede a aplicação. O produto final será um vídeo que documenta e explica todo o processo, desde a criação da infraestrutura (redes, permissões, VMs) até a aplicação estar em pleno funcionamento.
>
> Considere todos os passos e requisitos do Trabalho 1, com o acréscimo de um novo requisito de automação para a implantação.
>
> **Requisito Adicional: Automação da Implantação**
>
> A principal novidade deste trabalho é a obrigatoriedade de automatizar o processo de implantação da aplicação. Para isso, você deve cumprir o seguinte requisito:
>
> **REQ25:** Automatize a implantação da sua aplicação usando uma das seguintes opções:
>
> - Opção 1: Use Terraform para criar a infraestrutura.
> - Opção 2: Use Ansible para automatizar o processo de implantação.
>
> **Opcional: Uso de Outras Ferramentas de Nuvem**
>
> Para aqueles que desejam ir além, é permitido o uso de outras ferramentas de nuvem (além do OpenStack). Essa é uma escolha de sua responsabilidade, e a seleção da ferramenta deve ser discutida previamente com o professor. Exemplos de ferramentas incluem: Packstack, Microstack, Microcloud, OpenStack Kolla AIO (all-in-one), CloudStack, entre outras.
>
> Bom trabalho!
