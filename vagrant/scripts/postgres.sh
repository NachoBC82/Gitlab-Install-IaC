#!/bin/bash
# =============================================================================
# scripts/postgres.sh
#
# Aprovisionamiento base de los nodos dedicados a PostgreSQL (pg01, pg02, pg03),
# fuera del clúster de Kubernetes, pensados para servir como backend de
# GitLab en la arquitectura "Cloud Native Hybrid" (100 RPS / 5.000 usuarios).
#
# En esta primera iteración este script deja el nodo con PostgreSQL 16
# instalado, accesible desde la red interna y con una configuración de
# memoria/conexiones acorde al tamaño de VM (4 vCPU / 15 GB).
#
# Pendiente para próximas iteraciones (no se hace aquí todavía):
#   - Consul (para el descubrimiento de servicios de Patroni)
#   - Patroni (failover automático primario/réplicas)
#   - PgBouncer (pooling de conexiones)
# =============================================================================
set -euo pipefail
 
echo ">>> Nodo PostgreSQL ${POSTGRES_NODE_INDEX}/${POSTGRES_TOTAL_NODES}"
 
# --- DNS ---
if [ -n "${DNS_SERVERS:-}" ]; then
  for ns in $DNS_SERVERS; do
    echo "nameserver $ns" >> /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
  done
fi
 
# --- Repositorio oficial de PostgreSQL (PGDG) ---
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release
 
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
 
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
 
apt-get update -y
 
PG_VERSION=16
apt-get install -y "postgresql-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
 
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
 
# --- Acceso desde la red interna del laboratorio ---
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
 
# Permite conexiones desde el resto de nodos del rango 192.168.56.0/24
# (control-plane, workers y demás nodos PostgreSQL). Se ajustará más
# adelante cuando se añada PgBouncer/Patroni con reglas más finas.
if ! grep -q "192.168.56.0/24" "${PG_CONF_DIR}/pg_hba.conf"; then
  echo "host    all             all             192.168.56.0/24         scram-sha-256" \
    >> "${PG_CONF_DIR}/pg_hba.conf"
fi
 
# --- Tuning básico calculado según la RAM real de la VM ---
# Así el mismo script sirve tanto para el nodo de pruebas local (pocos GB)
# como para el nodo de producción (15 GB), sin tocar valores a mano.
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
SHARED_BUFFERS_MB=$(( TOTAL_MEM_MB / 4 ))          # ~25% RAM
EFFECTIVE_CACHE_MB=$(( TOTAL_MEM_MB * 3 / 4 ))     # ~75% RAM
MAINT_WORK_MEM_MB=$(( TOTAL_MEM_MB / 16 ))
if [ "$MAINT_WORK_MEM_MB" -lt 64 ]; then MAINT_WORK_MEM_MB=64; fi
if [ "$MAINT_WORK_MEM_MB" -gt 1024 ]; then MAINT_WORK_MEM_MB=1024; fi
 
# En una VM pequeña de pruebas, limitamos max_connections; en el nodo de
# producción (>=8GB) se usa el valor pensado para la carga de GitLab.
if [ "$TOTAL_MEM_MB" -ge 8192 ]; then
  MAX_CONNECTIONS=500
else
  MAX_CONNECTIONS=100
fi
 
cat <<EOF >> "${PG_CONF_DIR}/postgresql.conf"
 
# --- Tuning inicial (calculado automáticamente: ${TOTAL_MEM_MB}MB RAM detectados) ---
max_connections = ${MAX_CONNECTIONS}
shared_buffers = ${SHARED_BUFFERS_MB}MB
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
maintenance_work_mem = ${MAINT_WORK_MEM_MB}MB
work_mem = 16MB
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
EOF
 
systemctl enable "postgresql@${PG_VERSION}-main"
systemctl restart "postgresql@${PG_VERSION}-main"
 
echo ">>> PostgreSQL ${PG_VERSION} instalado y escuchando en 0.0.0.0:5432 (pg0${POSTGRES_NODE_INDEX})"
 