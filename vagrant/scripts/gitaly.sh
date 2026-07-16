#!/bin/bash
# =============================================================================
# scripts/gitaly.sh
#
# Aprovisionamiento base del nodo de Gitaly (almacenamiento y servicio de
# repositorios Git para GitLab), fuera del clúster de Kubernetes.
#
# Se instala con el paquete Linux (Omnibus) de GitLab CE, configurado para
# ejecutar ÚNICAMENTE el rol de Gitaly: se desactivan PostgreSQL, Redis,
# Puma, Sidekiq, Workhorse, etc. porque esos servicios ya viven en sus
# propios nodos (pg01, redis01...).
#
# En esta primera iteración: 1 nodo, SIN Praefect (sin Gitaly Cluster).
#
# Pendiente para próximas iteraciones (no se hace aquí todavía):
#   - Gitaly Cluster (Praefect): 3 nodos Gitaly + 3 Praefect + Postgres
#     dedicado para Praefect, con replicación y failover automático.
# =============================================================================
set -euo pipefail

echo ">>> Nodo Gitaly ${GITALY_NODE_INDEX}/${GITALY_TOTAL_NODES}"

apt-get update -y
apt-get install -y curl ca-certificates openssh-server

# --- Repositorio oficial de GitLab CE ---
if [ ! -f /etc/apt/sources.list.d/gitlab_gitlab-ce.list ]; then
  curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
fi

# --- Evitar que el post-install lance "gitlab-ctl reconfigure" con los
# valores por defecto (que levantaría TODOS los servicios). Lo haremos
# nosotros a mano después de escribir gitlab.rb con el rol de Gitaly. ---
mkdir -p /etc/gitlab
touch /etc/gitlab/skip-auto-reconfigure

apt-get install -y gitlab-ce

# --- Token de autenticación entre GitLab Rails y este nodo Gitaly ---
# Todos los nodos Gitaly del mismo clúster deben compartir el mismo token;
# como aquí solo hay 1 nodo, basta con generarlo una vez.
TOKEN_FILE="/root/.gitaly_token"
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
GITALY_TOKEN=$(cat "$TOKEN_FILE")

mkdir -p /var/opt/gitlab/git-data/repositories

cat > /etc/gitlab/gitlab.rb <<EOF
# Nodo dedicado exclusivamente a Gitaly: el resto de servicios de GitLab
# viven en sus propios nodos y se desactivan aquí.
postgresql['enable'] = false
redis['enable'] = false
nginx['enable'] = false
puma['enable'] = false
sidekiq['enable'] = false
gitlab_workhorse['enable'] = false
gitlab_kas['enable'] = false
grafana['enable'] = false
alertmanager['enable'] = false
prometheus['enable'] = false

gitaly['enable'] = true

# Escucha en todas las interfaces; el acceso se restringe por token y,
# en producción, por firewall/reglas de red.
gitaly['configuration'] = {
  listen_addr: '0.0.0.0:8075',
  auth: {
    token: '${GITALY_TOKEN}',
  },
  storage: [
    {
      name: 'default',
      path: '/var/opt/gitlab/git-data/repositories',
    },
  ],
}
EOF

gitlab-ctl reconfigure

echo ">>> Gitaly instalado y escuchando en gitaly0${GITALY_NODE_INDEX}:8075"
echo ">>> Token de autenticación en ${TOKEN_FILE} (solo legible por root)"
echo ">>> Repositorios almacenados en /var/opt/gitlab/git-data/repositories"
