#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 0. Checagem de pré-requisitos (com opção de instalar)
# ============================================================
echo "==> [0/4] Checando pré-requisitos..."

MISSING=()
command -v docker         >/dev/null 2>&1 || MISSING+=("docker.io")
command -v nft             >/dev/null 2>&1 || MISSING+=("nftables")
command -v wg               >/dev/null 2>&1 || MISSING+=("wireguard-tools")
docker compose version      >/dev/null 2>&1 || MISSING+=("docker-compose-plugin")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "    Faltando: ${MISSING[*]}"
  read -rp "    Instalar agora via apt? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
  else
    echo "    OK, pulando instalação. O script pode falhar sem essas dependências."
    echo "    Instale manualmente: sudo apt install -y ${MISSING[*]}"
  fi
else
  echo "    Tudo presente."
fi

# ============================================================
# 1. Chave SSH do bastion
# ============================================================
echo "==> [1/4] Gerando chave SSH do bastion (se ainda não existir)..."
if [ ! -f ./bastion/id_lab ]; then
  ssh-keygen -t ed25519 -N "" -f ./bastion/id_lab -q
  cp ./bastion/id_lab.pub ./bastion/authorized_keys
  echo "    Chave gerada em bastion/id_lab (privada) e bastion/id_lab.pub (pública)."
fi

# ============================================================
# 2. Subir containers
# ============================================================
echo "==> [2/4] Subindo containers (docker compose)..."
docker compose up -d --build

echo "==> [3/4] Aguardando serviços ficarem saudáveis..."
sleep 15

# ============================================================
# 3. Firewall (também com confirmação — altera regras do host)
# ============================================================
echo "==> [4/4] Aplicando ruleset de firewall no host..."
read -rp "    Isso vai alterar as regras de firewall do seu host. Continuar? [y/N] " ans_fw
if [[ "$ans_fw" =~ ^[Yy]$ ]]; then
  sudo nft -f nftables/ruleset.nft || {
    echo "AVISO: falha ao aplicar nftables. Rode manualmente: sudo nft -f nftables/ruleset.nft"
  }
else
  echo "    Pulado. A segmentação de rede via nftables NÃO está ativa."
  echo "    Aplique depois com: sudo nft -f nftables/ruleset.nft"
fi

echo ""
echo "Laboratório no ar."
echo "  - App via WAF:      https://localhost:8443"
echo "  - VPN (WireGuard):  cat ./wireguard/config/peer1/peer1.conf (QR code em peer1.png)"
echo "  - SSH admin:        ssh -i bastion/id_lab admin@172.28.40.10   (só funciona conectado à VPN)"
echo ""
echo "Para derrubar tudo: docker compose down -v && sudo nft flush ruleset"
