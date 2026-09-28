# Arquitetura AWS/EKS — Escalando o laboratório para produção

Este documento traduz a arquitetura do laboratório (Docker + nftables + WAF local)
para um desenho equivalente rodando em produção real, usando AWS e EKS.

## Mapeamento direto: laboratório para AWS

| Laboratório (Docker) | Equivalente AWS |
|---|---|
| Redes Docker (net_dmz, net_app, net_db) | VPC com subnets públicas/privadas por camada |
| nftables (firewall no host) | Security Groups + NACLs |
| WAF (ModSecurity + Nginx) | AWS WAF + Application Load Balancer (ALB) |
| DVWA (container) | Pod no EKS, atrás de um Service |
| MariaDB (container) | RDS (MySQL/Aurora), fora do cluster EKS |
| Bastion (SSH multi-rede) | AWS Systems Manager Session Manager |
| WireGuard (VPN) | AWS Client VPN ou Site-to-Site VPN |
| Restrição de rede por container (/32, app2) | Kubernetes Network Policies + Security Groups por pod |

## Separação de contas — Produção x Desenvolvimento

Usaria AWS Organizations para colocar Produção e Desenvolvimento em contas AWS
separadas, não apenas VPCs diferentes na mesma conta.

Estrutura: uma conta de gestão no topo, com duas Organizational Units — uma
para Produção (contendo a conta com dados reais, EKS e RDS de produção) e
outra para Desenvolvimento (contendo a conta de Dev/Staging).

Por que contas separadas em vez de VPCs separadas na mesma conta:

- Isolamento estrutural, não dependente de regra de rede bem configurada — o
  mesmo tipo de erro que corrigimos no laboratório (regra liberando a subnet
  inteira em vez do IP exato) fica fisicamente contido dentro da conta errada
- SCP bloqueia explicitamente qualquer tentativa de peering ou conexão
  cross-conta entre as duas OUs, mesmo que alguém tente criar isso manualmente
- IAM Roles e credenciais de Produção simplesmente não existem do ponto de
  vista da conta de Dev — não há nem "porta fechada" para tentar abrir
- Billing separado por conta, visibilidade de custo por ambiente

## VPC e rede

Cada conta tem sua própria VPC, dividida em quatro subnets: pública (ALB e
NAT Gateway), privada para APP (EKS worker nodes rodando os pods), privada
para DB (RDS) e privada para management (VPN endpoint e acesso administrativo).

Só o ALB fica exposto; workers do EKS e RDS nunca têm IP público — o mesmo
princípio do laboratório, onde só o WAF publicava porta, nunca o DVWA ou o
banco diretamente.

## Isolamento Dev x Produção — detalhamento

- Ambiente de Dev não é acessível externamente. Nenhum recurso de Dev tem
  rota para a internet pública. Reforçado por SCP na OU de Dev, bloqueando
  explicitamente a criação ou anexação de Internet Gateway na VPC de Dev, a
  criação de Security Group com regra de entrada aberta para qualquer
  origem, e a criação de ALB do tipo internet-facing.
- RDS de Dev nunca tem dado real. Populado via pipeline de dados
  sintéticos/mascarados. Verificação automática com Macie, escaneando
  periodicamente o RDS de Dev para confirmar que nenhum dado sensível real
  vazou para lá por engano.
- Produção exposta à internet, mas só através de WAF e proteção AntiDDoS
  (Shield) na frente do ALB público — o mesmo padrão de borda aplicado no
  laboratório com o WAF na frente do DVWA.

## Borda — WAF e entrada

AWS WAF anexado ao ALB, com AWS Managed Rules — equivalente gerenciado do
ModSecurity e OWASP CRS usado no laboratório, cobrindo os mesmos ataques
testados (SQLi, XSS). Diferente do laboratório, não é necessário gerenciar
patch ou versão do WAF manualmente — resolve o problema real que
documentamos, onde uma técnica de bypass (upload de arquivo .pht) só foi
corrigida numa versão específica do CRS.

Shield protege contra DDoS na borda. CloudFront fica na frente do ALB,
absorvendo tráfego e cacheando conteúdo. Route 53 com healthcheck permite
failover, redundância que o laboratório não tem hoje.

## Acesso administrativo — bastion versus Session Manager

Abordagem tradicional seria um bastion host por VPC, já que não há peering
entre Dev e Produção. Abordagem que eu adotaria de fato é o AWS Systems
Manager Session Manager, não bastion tradicional. Isso elimina três
problemas do modelo clássico: não precisa manter uma instância EC2 rodando
o tempo todo só para acesso administrativo, nenhuma porta SSH fica aberta
em nenhuma VPC em nenhum momento, e toda sessão é auditada automaticamente
via CloudTrail, sem depender de configurar logging manualmente no próprio
bastion, como tivemos que fazer no laboratório ao reconfigurar o sshd_config.

## Dentro do EKS — autenticação de pod com o banco

Em vez de senha fixa em variável de ambiente, como no laboratório, o pod
usaria EKS Pod Identity para assumir uma IAM Role e gerar credencial
temporária via RDS IAM Authentication, ou buscar o segredo dinamicamente
via Secrets Manager com CSI Driver. Mesmo mecanismo estudado durante a
preparação técnica para vagas de Cloud Security.

A associação é simplificada, sem federação OIDC manual, feita com o comando
abaixo:

aws eks create-pod-identity-association --cluster-name NOME_DO_CLUSTER --namespace app --service-account dvwa-sa --role-arn ARN_DA_ROLE

## Segmentação dentro do cluster

Kubernetes Network Policies restringem qual pod fala com qual — equivalente
direto da regra restrita a IP exato aplicada no laboratório, onde o DVWA só
alcança o banco, nada mais. Security Groups por pod, suportados pela VPC
CNI do EKS, funcionam como camada adicional.

## IAM e menor privilégio

Uma IAM Role por pod, via Pod Identity — nunca uma Role genérica
compartilhada por todo o cluster. O pod do DVWA teria uma Role própria, com
permissão só para conectar no banco específico, nada além disso. Roles
nomeadas por função, nunca por conveniência — não existe Role com acesso
administrativo total anexada a uma aplicação. Permission Boundaries
aplicadas nas contas de Dev limitam o teto de permissão que mesmo um
administrador de Dev pode conceder a uma Role nova, impedindo escalada de
privilégio mesmo por erro humano de configuração.

## Boas práticas de EKS aplicadas

Baseado no estudo prévio feito para vagas de Cloud Security:

- Cluster Access Management API (Access Entry e Access Policy) no lugar do
  ConfigMap aws-auth legado, integrado a IAM Identity Center para acesso
  baseado em grupo, não em usuário individual
- EKS Pod Identity no lugar de IRSA para autenticação de pod com serviços
  AWS — menos configuração manual, mais fácil de replicar entre clusters
- Pod Security Standards aplicados por namespace, restringindo privilégio
  de execução dos containers
- Network Policies para segmentação leste-oeste dentro do cluster
- Gestão de secrets via ASCP (CSI Driver) ou External Secrets Operator,
  nunca variável de ambiente com valor fixo
- Amazon Inspector escaneando as imagens de container por CVE conhecida
  antes de qualquer deploy

## Stack de governança e detecção

| Serviço | Contribuição para este ambiente |
|---|---|
| AWS Organizations | Isola Produção de Desenvolvimento em contas separadas |
| SCPs | Bloqueiam peering entre as OUs e exposição externa indevida de recursos de Dev |
| Landing Zone (Control Tower) | Garante que toda conta nova já nasce com CloudTrail, Config e guardrails ativos |
| IAM Identity Center | Autenticação federada, sem usuário IAM individual nem SSH key espalhada |
| IAM Access Analyzer | Detecta recurso acessível de fora da conta por engano |
| CloudTrail | Registra toda chamada de API, auditável para qualquer tentativa de escalada de privilégio |
| GuardDuty | Detecção por ML de comportamento anômalo, o que simulamos manualmente com o container app2 |
| Security Hub | Consolida achados de GuardDuty, Inspector e Config num painel único |
| AWS Config | Avalia o estado de cada recurso contra regras, pegando desvios como um Security Group aberto demais |
| Security Lake | Centraliza logs de segurança em formato único, resolvendo a dispersão de log por container |
| KMS | Criptografa RDS e Secrets Manager em repouso |
| VPC e NACL | Filtro stateless por subnet, equivalente mais próximo do nftables do laboratório |
| PrivateLink | Permite o pod acessar serviços AWS sem passar pela internet pública |
| EventBridge | Orquestra resposta automática a eventos de segurança |
| Inspector | Escaneia a imagem do container por CVE conhecida antes de rodar |
| Macie | Escaneia o RDS de Dev periodicamente, confirmando que nenhum dado real vazou para lá |

## Resumo — o que fica estruturalmente mais forte na AWS

| Problema enfrentado no laboratório | Como a arquitetura AWS resolve |
|---|---|
| Módulo de kernel instável entre bridges Docker | Não existe — a VPC CNI do EKS roteia entre pods nativamente |
| WAF exigindo atualização manual de versão | AWS Managed Rules atualiza automaticamente |
| Senha de banco fixa em variável de ambiente | Secrets Manager e Pod Identity, sem senha fixa em lugar nenhum |
| Bastion multi-rede fisicamente presente em todos os segmentos | Session Manager, zero porta administrativa aberta |
| Regra de firewall corrigida manualmente após teste | AWS Config detecta esse desvio automaticamente e sinaliza |
