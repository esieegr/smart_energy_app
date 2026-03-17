#!/bin/bash
# =============================================================================
# install_kafka_pi.sh — Installation de Kafka sur Raspberry Pi
# =============================================================================
# Ce script :
#   1. Met à jour le système
#   2. Installe Docker + Docker Compose
#   3. Démarre Kafka (KRaft) + Confluent REST Proxy
#   4. Crée le topic 'domoticz-events'
#   5. Vérifie que tout fonctionne
#
# Usage :
#   chmod +x install_kafka_pi.sh
#   sudo ./install_kafka_pi.sh
#
# Prérequis :
#   - Raspberry Pi OS 64-bit (Bullseye ou Bookworm) — recommandé pour ARM64
#   - Au moins 1 Go de RAM disponible
#   - Connexion Internet
# =============================================================================

set -e  # arrête le script à la première erreur
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo " Installation Kafka sur Raspberry Pi"
echo "========================================"

# ── 1. Récupérer l'IP du Pi ──────────────────────────────────────────────────
RASPBERRY_IP=$(hostname -I | awk '{print $1}')
echo "IP détectée : $RASPBERRY_IP"
export RASPBERRY_IP

# ── 2. Mise à jour système ───────────────────────────────────────────────────
echo ""
echo "[1/5] Mise à jour du système..."
apt-get update -qq
apt-get upgrade -y -qq

# ── 3. Installation Docker ───────────────────────────────────────────────────
echo ""
echo "[2/5] Installation de Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    usermod -aG docker $SUDO_USER
    echo "Docker installé."
else
    echo "Docker déjà installé : $(docker --version)"
fi

# Docker Compose plugin
if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin
fi
echo "Docker Compose : $(docker compose version)"

# ── 4. Démarrage de Kafka ────────────────────────────────────────────────────
echo ""
echo "[3/5] Démarrage de Kafka + REST Proxy..."
cd "$SCRIPT_DIR"

# Crée le fichier .env avec l'IP du Pi
echo "RASPBERRY_IP=$RASPBERRY_IP" > .env

docker compose pull --quiet
docker compose up -d

# Attente que Kafka soit prêt (max 90s)
echo "Attente de Kafka..."
for i in $(seq 1 18); do
    if docker exec kafka kafka-broker-api-versions \
        --bootstrap-server localhost:9092 &>/dev/null; then
        echo "Kafka prêt."
        break
    fi
    echo "  Tentative $i/18..."
    sleep 5
done

# Attente REST Proxy (max 60s)
echo "Attente du REST Proxy..."
for i in $(seq 1 12); do
    if curl -s http://localhost:8082/topics &>/dev/null; then
        echo "REST Proxy prêt."
        break
    fi
    echo "  Tentative $i/12..."
    sleep 5
done

# ── 5. Création du topic ─────────────────────────────────────────────────────
echo ""
echo "[4/5] Création du topic 'domoticz-events'..."
docker exec kafka kafka-topics \
    --bootstrap-server localhost:9092 \
    --create \
    --topic domoticz-events \
    --partitions 1 \
    --replication-factor 1 \
    --if-not-exists

echo "Topics existants :"
docker exec kafka kafka-topics \
    --bootstrap-server localhost:9092 \
    --list

# ── 6. Vérification finale ───────────────────────────────────────────────────
echo ""
echo "[5/5] Vérification..."

echo "Statut des conteneurs :"
docker compose ps

echo ""
echo "Test du REST Proxy (GET /topics) :"
curl -s http://localhost:8082/topics | python3 -m json.tool 2>/dev/null || \
    echo "Réponse brute : $(curl -s http://localhost:8082/topics)"

echo ""
echo "========================================"
echo " Installation terminée !"
echo "========================================"
echo ""
echo "  Kafka broker   : $RASPBERRY_IP:9092"
echo "  REST Proxy     : $RASPBERRY_IP:8082"
echo "  Topic          : domoticz-events"
echo ""
echo "Dans l'app Flutter :"
echo "  Paramètres → Kafka → IP = $RASPBERRY_IP"
echo "  Port = 8082   Topic = domoticz-events"
echo ""
echo "Commandes utiles :"
echo "  docker compose logs -f kafka        # logs Kafka"
echo "  docker compose logs -f kafka-rest   # logs REST Proxy"
echo "  docker compose down                 # arrêter"
echo "  docker compose up -d               # redémarrer"
