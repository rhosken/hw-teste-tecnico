# Teste Técnico — Segurança da Informação (H&W)

## Como rodar localmente

```bash
git clone <seu-repo>
cd hw-teste-tecnico
./up.sh
```

Requisitos: Linux (nativo ou VM), Docker + Docker Compose v2, nftables, sudo.
Desenvolvido em Ubuntu 24.04 via Multipass, para desenvolvimento em macOS.

## 1. Topologia e Segmentação

Fluxo de tráfego:

- Internet -> porta 8443/tcp -> WAF (DMZ, 172.28.10.0/24) -> DVWA (APP, 172.28.20.0/24) -> MariaDB (DB, 172.28.30.0/24)
- Internet -> porta 51820/udp -> WireGuard (VPN, 172.28.40.0/24) -> Bastion (admin, presente nas 4 redes)

Segmentação em duas camadas:
1. Redes Docker separadas (isolamento nativo de bridge)
2. nftables no host, com política default-deny e liberações explícitas por IP exato (/32)

Ruleset completo: [nftables/ruleset.nft](nftables/ruleset.nft)

## 2. Mapa da Superfície de Ataque

Recon feito a partir de dois pontos (ver [evidence/parte2-recon/](evidence/parte2-recon/)):

| Ponto de origem | O que é visível | Por que interessa a um atacante |
|---|---|---|
| Host/Internet | Só porta 8443 (WAF) | Único ponto de entrada real |
| Dentro da DMZ (WAF comprometido) | bastion:22, dvwa:80, waf:8080/8443 | Mapa completo da rede interna, incluindo achado do bastion exposto (ver seção 5) |

Achados de recon:
- [evidence/parte2-recon/nmap-host-fullscan.txt](evidence/parte2-recon/nmap-host-fullscan.txt) — scan completo do host
- [evidence/parte2-recon/nmap-dmz-to-app.txt](evidence/parte2-recon/nmap-dmz-to-app.txt) — scan de dentro da DMZ
- [evidence/parte2-recon/achado-healthz.txt](evidence/parte2-recon/achado-healthz.txt) — endpoint `/healthz` sem autenticação, único a passar em meio a 4.751 tentativas de enumeração de diretórios (ffuf)

## 3. Relatório de Pentest — Cadeia de Ataque

Três vulnerabilidades exploradas, foothold, movimento lateral e exfiltração de dados. Todos os relatórios em [evidence/parte3-exploitation/](evidence/parte3-exploitation/).

### Achado #1 — SQL Injection ([achado-1-sqli/relatorio.txt](evidence/parte3-exploitation/achado-1-sqli/relatorio.txt))
- Payload `1' OR '1'='1` no módulo SQL Injection vazou a tabela `users` inteira (5 registros). Print: [sqli.png](evidence/parte3-exploitation/achado-1-sqli/sqli.png)

### Achado #2 — Reflected XSS ([achado-2-xss/relatorio.txt](evidence/parte3-exploitation/achado-2-xss/relatorio.txt))
- Payload `<script>alert('XSS')</script>` executado sem encoding no módulo XSS Reflected. Print: [xss.png](evidence/parte3-exploitation/achado-2-xss/xss.png)

### Achado #3 — Command Injection / Foothold ([achado-3-cmdi/relatorio.txt](evidence/parte3-exploitation/achado-3-cmdi/relatorio.txt))
- Payload `127.0.0.1 && whoami` no módulo Command Injection
- Execução confirmada como `www-data` (uid=33), dentro do container `dvwa`. Print: [cmdi-whoami.png](evidence/parte3-exploitation/achado-3-cmdi/cmdi-whoami.png)

### Movimento lateral ([movimento-lateral/relatorio.txt](evidence/parte3-exploitation/movimento-lateral/relatorio.txt))
- A partir do foothold em `dvwa`, confirmado alcance de rede até o banco (`nc -zv db 3306`)
- Reproduzido via Command Injection real: `127.0.0.1 && nc -zv db 3306 2>&1`. Print: [cmdi-netcat.png](evidence/parte3-exploitation/movimento-lateral/cmdi-netcat.png)

### Exfiltração ([exfiltracao/relatorio.txt](evidence/parte3-exploitation/exfiltracao/relatorio.txt))
- `UNION SELECT user, password FROM users` extraiu usuário e hash de senha de todas as 5 contas. Print: [sqli-exfiltracao.png](evidence/parte3-exploitation/exfiltracao/sqli-exfiltracao.png)
- Hashes MD5 ([hashes.txt](evidence/parte3-exploitation/exfiltracao/hashes.txt)) quebrados usando [hashcat](https://hashcat.net/wiki/doku.php?id=hashcat) + [wordlist pública](https://github.com/danielmiessler/SecLists/blob/master/Passwords/Leaked-Databases/rockyou-75.txt) em menos de 3 segundos. Senhas quebradas em [senhas-quebradas.txt](evidence/parte3-exploitation/exfiltracao/senhas-quebradas.txt)

### Cadeia completa (kill chain)
Recon (ffuf/nmap) -> SQLi (foothold via dados) -> Command Injection (shell como www-data) -> Movimento lateral (APP -> DB via nc) -> Exfiltração (UNION SELECT + quebra de hash)

## 4. WAF — Bloqueio, Bypass e Correção

Evidências em [evidence/parte4-waf/](evidence/parte4-waf/).

### Bloqueios confirmados
- SQLi: 403, regra ModSecurity 942100 (libinjection), score 5 — [bloqueio-sqli/relatorio.txt](evidence/parte4-waf/bloqueio-sqli/relatorio.txt)
- XSS: 403, 4 regras simultâneas (941100/941110/941160/941390), score 20 — [bloqueio-xss/relatorio.txt](evidence/parte4-waf/bloqueio-xss/relatorio.txt)

### Tentativa de bypass ([tentativa-bypass/](evidence/parte4-waf/tentativa-bypass/))
Resumo completo em linguagem simples com todos os comandos: [resumo-simples.txt](evidence/parte4-waf/tentativa-bypass/resumo-simples.txt)

Testado em 5 frentes:
1. 8 técnicas manuais de ofuscação em SQLi (comentários, encoding duplo, parameter pollution, etc.)
2. [sqlmap](https://github.com/sqlmapproject/sqlmap) com tamper scripts — 8.059 requisições, todas bloqueadas. Resultado: [sqlmap-output.txt](evidence/parte4-waf/tentativa-bypass/sqlmap-output.txt)
3. Troca de vetor (Command Injection, File Inclusion, XSS DOM/Stored)
4. [XSStrike](https://github.com/s0md3v/XSStrike) com fuzzer — identificou tags que passavam isoladamente, mas nenhuma combinação weaponizada funcionou. Resultado: [xsstrike-output.txt](evidence/parte4-waf/tentativa-bypass/xsstrike-output.txt)

**Conclusão:** nenhum bypass encontrado após configuração do WAF.

## 5. Hardening — Antes/Depois

Evidências em [evidence/parte5-hardening/](evidence/parte5-hardening/).

| Elo | Mitigação aplicada | Evidência |
|---|---|---|
| Command Injection | WAF bloqueia (regras 932xxx) | [cmdi/relatorio.txt](evidence/parte5-hardening/cmdi/relatorio.txt) |
| Movimento lateral APP->DB | Regra de firewall restrita de subnet inteira para IP exato (/32) | [movimento-lateral/relatorio.txt](evidence/parte3-exploitation/movimento-lateral/relatorio.txt) |

Testei a hipótese com um container novo (`app2`) antes e depois da correção. Além das Regras 1 e 2, a Regra 4 (Internet->WAF) também foi restringida a IP exato. A Regra 3 (VPN->Bastion) foi mantida em subnet, já que peers de VPN recebem IP dinâmico. Todo o hardening do firewall pode ser vista no link [movimento-lateral/relatorio.txt](evidence/parte5-hardening/movimento-lateral/relatorio.txt)

## 6. Mapeamento de Portas (Final)

Relatório completo com scans antes/depois (portas completas, -p-) em [evidence/parte6-mapeamento/relatorio.txt](evidence/parte6-mapeamento/relatorio.txt).

| Host | Porta | Protocolo | Quem pode acessar | Justificativa |
|---|---|---|---|---|
| WAF | 8443 | TCP | Internet (qualquer origem) | Único ponto de entrada público |
| WAF | 51820 | UDP | Internet (qualquer origem) | Porta da VPN |
| DVWA | 80 | TCP | Só o WAF (IP exato /32) | App nunca exposta direto |
| DB | 3306 | TCP | Só o DVWA (IP exato /32) | Banco nunca exposto à APP toda |
| Bastion | 22 | TCP | VPN (via restrição no SSH) | Acesso administrativo |

**Prova de bloqueio:** DMZ->DB recusado (timeout), confirmado em [evidence/parte1-segmentacao/](evidence/parte1-segmentacao/) e reconfirmado com `app2` na Parte 5.

**Achado extra (fora da cadeia da Parte 3):** o bastion continuava com SSH visível para qualquer host na rede APP, mesmo devendo ser só-VPN. Corrigido restringindo a autenticação diretamente no `sshd_config` do bastion (`Match Address`), testado e confirmado com senha correta recusada fora da VPN ([evidence/parte6-mapeamento/bastion-hardening/](evidence/parte6-mapeamento/bastion-hardening/)).

## Trade-offs, limitações e como escalaria para a infra real

- **Ambiente de laboratório vs. produção:** todo o ambiente roda em containers Docker dentro de uma única VM. Em produção, cada segmento seria uma subnet real (AWS VPC), com Security Groups e NACLs no lugar do nftables, e um WAF gerenciado (AWS WAF, Cloudflare) na borda em vez do ModSecurity self-hosted.
- **Bastion multi-rede:** o desenho atual prioriza simplicidade de laboratório; em produção, o ideal seria um bastion dedicado só à rede de management, acessando os demais segmentos via VPN peering.
- **br_netfilter e ambiente Multipass:** identifiquei que esse módulo do kernel, necessário para o nftables inspecionar tráfego entre bridges Docker, causa instabilidade nesse ambiente específico (VM aninhada). Não afeta um servidor Linux real/dedicado.

## Ferramental ofensivo utilizado

| Ferramenta | Uso no fluxo |
|---|---|
| nmap | Descoberta de hosts/portas/serviços |
| ffuf | Enumeração de diretórios/endpoints |
| sqlmap | Exploração e tentativa de bypass automatizado de SQLi |
| XSStrike | Fuzzing e tentativa de bypass de XSS |
| hashcat | Quebra de hashes MD5 extraídos via SQLi |
| curl / netcat | Testes manuais, reprodução de payloads, testes de conectividade |
