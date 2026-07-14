#!/bin/bash
# =============================================================================
# scripts/redis.sh
#
# Aprovisionamiento base de los nodos dedicados a Redis (redis01, redis02...),
# fuera del clúster de Kubernetes, pensados como backend de sesiones, caché
# y colas de Sidekiq para GitLab (arquitectura "Cloud Native Hybrid").
#
# En esta primera iteración este script deja el nodo con Redis instalado,
# accesible desde la red interna y con contraseña. Es un único nodo, SIN
# Sentinel todavía (eso llega cuando pasemos a los 3 nodos de producción).
#
# Pendiente para próximas iteraciones (no se hace aquí todavía):
#   - Redis Sentinel (failover automático, requiere 3 nodos y Consul)
#   - Separación en instancias Cache / Persistent (recomendado a partir
#     de arquitecturas más grandes que la de 5.000 usuarios)
# =============================================================================
set -euo pipefail

echo ">>> Nodo Redis ${REDIS_NODE_INDEX}/${REDIS_TOTAL_NODES}"

# --- DNS ---
if [ -n "${DNS_SERVERS:-}" ]; then
  for ns in $DNS_SERVERS; do
    echo "nameserver $ns" >> /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
  done
fi

apt-get update -y
apt-get install -y redis-server openssl

REDIS_CONF="/etc/redis/redis.conf"

# --- Contraseña ---
# Se genera una contraseña aleatoria por nodo y se guarda en un fichero
# solo legible por root, para poder recuperarla al hacer pruebas desde
# otra VM. En el paso de Sentinel, todos los nodos del clúster deberán
# compartir la MISMA contraseña (se homogeneizará entonces).
PASS_FILE="/root/.redis_password"
if [ ! -f "$PASS_FILE" ]; then
  openssl rand -hex 16 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
REDIS_PASSWORD=$(cat "$PASS_FILE")

# --- Acceso desde la red interna del laboratorio ---
sed -i "s/^bind .*/bind 0.0.0.0 -::1/" "$REDIS_CONF"
sed -i "s/^protected-mode .*/protected-mode yes/" "$REDIS_CONF"
sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" "$REDIS_CONF"
if ! grep -q "^requirepass" "$REDIS_CONF"; then
  echo "requirepass ${REDIS_PASSWORD}" >> "$REDIS_CONF"
fi

# --- Política de memoria ---
# GitLab usa Redis tanto para caché como para colas de Sidekiq (datos que
# NO se pueden perder), así que en el nodo combinado se evita el
# desalojo automático de claves.
sed -i "s/^# maxmemory-policy .*/maxmemory-policy noeviction/" "$REDIS_CONF"
if ! grep -q "^maxmemory-policy" "$REDIS_CONF"; then
  echo "maxmemory-policy noeviction" >> "$REDIS_CONF"
fi

systemctl enable redis-server
systemctl restart redis-server

echo ">>> Redis instalado y escuchando en 0.0.0.0:6379 (redis0${REDIS_NODE_INDEX})"
echo ">>> Contraseña generada en ${PASS_FILE} (solo legible por root)"