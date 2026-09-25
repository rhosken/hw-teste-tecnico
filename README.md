# Teste Técnico — Segurança da Informação (H&W)

## Como rodar localmente

```bash
git clone <seu-repo>
cd hw-lab
./up.sh
```

Requisitos: Docker + Docker Compose v2, `nft` (nftables), `sudo` para aplicar o firewall no host.

## 1. Topologia e Segmentação

<!-- TODO: cole aqui o diagrama (pode ser o ASCII do enunciado adaptado, ou uma imagem em /evidence) -->

Segmentos:
- **VPN** (172.28.40.0/24) — único ponto de entrada administrativa (WireGuard)
- **DMZ** (172.28.10.0/24) — WAF/reverse proxy, único ponto de entrada público
- **APP** (172.28.20.0/24) — DVWA, só recebe do WAF
- **DB** (172.28.30.0/24) — MariaDB, só recebe da APP

Isolamento em duas camadas: redes Docker separadas (L3 nativo) + nftables no host com
política default-deny e allow explícito (`nftables/ruleset.nft`).

## 2. Mapa da Superfície de Ataque

<!-- TODO Parte 2: recon a partir de host/internet, VPN e de dentro da DMZ.
     nmap -sV -p- a partir de cada ponto; ffuf/gobuster no alvo; anexar saídas em /evidence/recon -->

| Ponto de origem | O que é visível | Por que interessa a um atacante |
|---|---|---|
| Internet (host) | porta 8443 (WAF) | único ponto de entrada; superfície pública real |
| Dentro da VPN | 22 (bastion) | admin — alvo de movimento lateral pós-comprometimento |
| Dentro da DMZ | 80/tcp da APP | ponto de pivô se o WAF for contornado |

## 3. Relatório de Pentest — Cadeia de Ataque

<!-- TODO Parte 3: para cada achado, siga este template -->

### Achado #1 — <nome, ex: SQL Injection em login.php>
- **Severidade (CVSS aprox.):**
- **Passos de reprodução:**
- **Evidência:** ver `/evidence/exploitation/achado-1/`
- **Impacto:**

### Achado #2 — ...

### Cadeia completa (kill chain)
1. Recon → 2. Exploração inicial (foothold DMZ) → 3. Movimento lateral (DMZ→APP→DB) → 4. Exfiltração

## 4. WAF — Bloqueio, Bypass e Correção

<!-- TODO Parte 4 -->
- Requisição bloqueada (403) + log do ModSecurity: `/evidence/waf/blocked/`
- Tentativa de bypass (encoding/ofuscação) que passou: `/evidence/waf/bypass/`
- Regra customizada que fecha o bypass: `waf/custom-rules/`
- Requisição legítima continuando a passar após o ajuste: `/evidence/waf/legit-after-fix/`

## 5. Hardening — Antes/Depois

<!-- TODO Parte 5: uma linha por elo da cadeia fechado -->

| Elo da cadeia | Mitigação aplicada | Evidência antes | Evidência depois |
|---|---|---|---|
| ex: SQLi | Patch de sanitização + regra WAF | `/evidence/before/` | `/evidence/after/` |

## 6. Mapeamento de Portas (Final)

<!-- TODO Parte 6: nmap antes/depois, tabela completa -->

| Host | Porta | Protocolo | Quem pode acessar | Justificativa |
|---|---|---|---|---|
| WAF (DMZ) | 8080/8443 | TCP | Internet | único ponto público |
| DVWA (APP) | 80 | TCP | Só DMZ (WAF) | nunca exposto direto |
| MariaDB (DB) | 3306 | TCP | Só APP | nunca DMZ, nunca internet |
| Bastion | 22 | TCP | Só VPN | admin exclusivo via túnel |

Prova de bloqueio: `DMZ -> DB` recusado — ver `/evidence/final/dmz-to-db-blocked.txt`

## Trade-offs, limitações e como escalaria para a infra real

<!-- TODO: discutir mapeamento para AWS (Security Groups/NACL), Cloudflare na borda,
     Proxmox na virtualização, OVH/Contabo -->

## Ferramental ofensivo utilizado

| Ferramenta | Uso no fluxo |
|---|---|
| nmap | Descoberta de hosts/portas/serviços |
| ffuf / gobuster | Enumeração de diretórios/endpoints |
| sqlmap | Exploração automatizada de SQLi |
| curl / netcat | Testes manuais e exfiltração |
