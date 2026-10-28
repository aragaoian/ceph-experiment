#!/bin/bash
# no.sh - inicializa um nó Ceph de laboratório (mon + osd [+ mgr no nó 1])
# Variáveis esperadas (vindas do docker-compose): NODE_ID, NODE_IP
# Config compartilhada: /etc/ceph/ceph.conf (somente leitura)
set -euo pipefail

: "${NODE_ID:?defina NODE_ID}"
: "${NODE_IP:?defina NODE_IP}"

CONF=/etc/ceph/ceph.conf
log() { echo "[no.sh ceph${NODE_ID}] $*" >&2; }

# ---------------------------------------------------------------------------
# 0. Parâmetros derivados
# ---------------------------------------------------------------------------
# fsid: usa o do ceph.conf se existir; senão, um valor fixo igual em todos os nós
FSID=$(awk -F= '/^[[:space:]]*fsid[[:space:]]*=/{gsub(/[ \t\r]/,"",$2); print $2; exit}' "$CONF" || true)
FSID=${FSID:-5b8a1c3e-7d2f-4e6a-9c10-0a1b2c3d4e5f}

# Lista de monitores a partir de mon_host (ex.: "172.30.0.11, 172.30.0.12, 172.30.0.13")
MON_IPS=$(awk -F= '/^[[:space:]]*mon_host[[:space:]]*=/{sub(/#.*/,"",$2); gsub(/[ \t\r]/,"",$2); print $2; exit}' "$CONF" | tr ',' ' ')
[ -n "$MON_IPS" ] || { log "mon_host não encontrado em $CONF"; exit 1; }

# Este nó roda mon se o seu IP estiver em mon_host (o ceph4 "extra" só roda OSD)
MON_ID=""
idx=0
for ip in $MON_IPS; do
  idx=$((idx + 1))
  if [ "$ip" = "$NODE_IP" ]; then MON_ID="ceph${idx}"; fi
done

# Todas as ferramentas ceph (CLI e daemons) herdam isto
# (garante cephx desligado nas três "pontas" e o fsid correto)
export CEPH_ARGS="--fsid ${FSID} --auth-cluster-required none --auth-service-required none --auth-client-required none"

# Daemons: ficam em primeiro plano e logam no stderr (docker logs)
DAEMON_OPTS="-f --default-log-to-file=false --default-log-to-stderr=true --err-to-stderr=true"

mkdir -p /var/lib/ceph/mon /var/lib/ceph/osd /var/lib/ceph/mgr /var/run/ceph /var/log/ceph /tmp

PIDS=()
stop_daemons() {
  log "encerrando daemons..."
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
shutdown() {
  stop_daemons
  exit 0
}
trap shutdown SIGTERM SIGINT

# ---------------------------------------------------------------------------
# 1. Monitor
# ---------------------------------------------------------------------------
if [ -n "$MON_ID" ]; then
  MON_DIR=/var/lib/ceph/mon/ceph-${MON_ID}
  if [ ! -d "$MON_DIR" ]; then
    log "criando monmap e store do monitor ${MON_ID}"
    rm -f /tmp/monmap
    monmaptool --create --fsid "$FSID" --clobber /tmp/monmap >/dev/null
    i=0
    for ip in $MON_IPS; do
      i=$((i + 1))
      monmaptool --addv "ceph${i}" "[v2:${ip}:3300/0,v1:${ip}:6789/0]" /tmp/monmap >/dev/null
    done
    # keyring "dummy": o mkfs do mon pede um, mesmo com cephx desligado
    ceph-authtool --create-keyring /tmp/mon.keyring --gen-key -n mon. --cap mon 'allow *' >/dev/null
    ceph-mon --mkfs -i "$MON_ID" --monmap /tmp/monmap --keyring /tmp/mon.keyring
  fi

  log "iniciando ceph-mon ${MON_ID} em ${NODE_IP}"
  ceph-mon -i "$MON_ID" --public-addr "$NODE_IP" $DAEMON_OPTS &
  PIDS+=($!)
fi

# ---------------------------------------------------------------------------
# 2. Espera o quórum (maioria dos monitores)
# ---------------------------------------------------------------------------
NEED=$(( $(wc -w <<<"$MON_IPS") / 2 + 1 ))
log "aguardando quórum (>= ${NEED} mons)..."
until [ "$(
  ceph quorum_status -f json --connect-timeout 5 2>/dev/null \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["quorum"]))' 2>/dev/null \
    || echo 0
)" -ge "$NEED" ]; do
  sleep 2
done
log "quórum formado"

# ---------------------------------------------------------------------------
# 3. Manager (somente nó 1)
# ---------------------------------------------------------------------------
if [ "$NODE_ID" = "1" ]; then
  MGR_ID=ceph1
  mkdir -p "/var/lib/ceph/mgr/ceph-${MGR_ID}"
  log "iniciando ceph-mgr ${MGR_ID}"
  ceph-mgr -i "$MGR_ID" $DAEMON_OPTS &
  PIDS+=($!)
fi

# ---------------------------------------------------------------------------
# 4. OSD (registra, formata e inicia)
# ---------------------------------------------------------------------------
OSD_STATE=/var/lib/ceph/osd/.node-osd   # guarda "<id> <uuid>" para reinícios
if [ -f "$OSD_STATE" ]; then
  read -r OSD_ID OSD_UUID < "$OSD_STATE"
else
  OSD_UUID=$(cat /proc/sys/kernel/random/uuid)
  log "registrando OSD (uuid ${OSD_UUID})"
  OSD_ID=$(ceph osd new "$OSD_UUID" --connect-timeout 30)
  echo "$OSD_ID $OSD_UUID" > "$OSD_STATE"
fi

OSD_DIR=/var/lib/ceph/osd/ceph-${OSD_ID}
OSD_OPTS="--osd-data ${OSD_DIR} --osd-objectstore bluestore --bluestore-block-path ${OSD_DIR}/block.file"

if [ ! -f "${OSD_DIR}/ready" ]; then
  log "formatando osd.${OSD_ID} (BlueStore em arquivo)"
  mkdir -p "$OSD_DIR"
  ceph-osd -i "$OSD_ID" --mkfs --osd-uuid "$OSD_UUID" $OSD_OPTS \
    --default-log-to-file=false --default-log-to-stderr=true
fi

log "iniciando osd.${OSD_ID} (host = $(hostname -s))"
# osd_crush_update_on_start (padrão) coloca o OSD sob host=<hostname> no mapa CRUSH
ceph-osd -i "$OSD_ID" $OSD_OPTS --public-addr "$NODE_IP" --cluster-addr "$NODE_IP" $DAEMON_OPTS &
PIDS+=($!)

# ---------------------------------------------------------------------------
# 5. Mantém o contêiner vivo; se algum daemon morrer, sai com erro
#    (o Docker/restart policy pode reiniciar o nó)
# ---------------------------------------------------------------------------
if wait -n; then
  DAEMON_STATUS=0
else
  DAEMON_STATUS=$?
fi
log "um dos daemons terminou; encerrando o contêiner"
stop_daemons
exit "${DAEMON_STATUS:-1}"
