#!/bin/bash
# =============================================================================
# scripts/minio.sh
#
# Aprovisionamiento base del nodo de almacenamiento de objetos self-hosted
# (MinIO, compatible con la API S3), usado por GitLab para LFS, artifacts,
# uploads, paquetes, backups, etc. en lugar de un proveedor cloud.
#
# En esta primera iteración: 1 nodo en modo "standalone" (sin erasure
# coding), solo para validar que el servicio levanta y es accesible.
#
# Pendiente para próximas iteraciones (no se hace aquí todavía):
#   - Modo distribuido con erasure coding (mínimo 4 nodos) para HA real
#   - Políticas de ciclo de vida / cifrado en reposo
# =============================================================================
set -euo pipefail

echo ">>> Nodo MinIO ${MINIO_NODE_INDEX}/${MINIO_TOTAL_NODES}"

# --- DNS ---
if [ -n "${DNS_SERVERS:-}" ]; then
  for ns in $DNS_SERVERS; do
    echo "nameserver $ns" >> /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
  done
fi

apt-get update -y
apt-get install -y curl openssl

# --- Binario de MinIO ---
if [ ! -f /usr/local/bin/minio ]; then
  curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio \
    -o /usr/local/bin/minio
  chmod +x /usr/local/bin/minio
fi

# --- Cliente mc (para crear los buckets de GitLab automáticamente) ---
if [ ! -f /usr/local/bin/mc ]; then
  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
    -o /usr/local/bin/mc
  chmod +x /usr/local/bin/mc
fi

# --- Usuario, grupo y directorio de datos ---
id -u minio-user >/dev/null 2>&1 || useradd -r minio-user -s /sbin/nologin
mkdir -p /data/minio
chown -R minio-user:minio-user /data/minio

# --- Credenciales root ---
# Se generan una sola vez y quedan guardadas solo para root. Serán las
# que uses luego para configurar GitLab (object_store) y para entrar
# a la consola web de MinIO.
CRED_FILE="/root/.minio_credentials"
if [ ! -f "$CRED_FILE" ]; then
  {
    echo "MINIO_ROOT_USER=gitlab-admin"
    echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi
# shellcheck disable=SC1090
source "$CRED_FILE"

# --- Fichero de entorno para el servicio systemd ---
cat > /etc/default/minio <<EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_VOLUMES="/data/minio"
MINIO_OPTS="--address :9000 --console-address :9001"
EOF

# --- Unidad systemd ---
cat > /etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO Object Storage
After=network-online.target
Wants=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio
systemctl restart minio

# --- Esperar a que la API esté lista y crear los buckets que usa GitLab ---
for i in $(seq 1 15); do
  curl -fsS "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1 && break
  sleep 2
done

/usr/local/bin/mc alias set local http://127.0.0.1:9000 \
  "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null

for bucket in gitlab-lfs gitlab-artifacts gitlab-uploads gitlab-packages \
              gitlab-mr-diffs gitlab-terraform-state gitlab-pages \
              gitlab-registry gitlab-backups; do
  /usr/local/bin/mc mb --ignore-existing "local/${bucket}"
done

echo ">>> MinIO instalado. API en http://minio0${MINIO_NODE_INDEX}:9000, consola en :9001"
echo ">>> Credenciales en ${CRED_FILE} (solo legible por root)"
echo ">>> Buckets de GitLab creados: gitlab-lfs, gitlab-artifacts, gitlab-uploads, gitlab-packages, gitlab-mr-diffs, gitlab-terraform-state, gitlab-pages, gitlab-registry, gitlab-backups"