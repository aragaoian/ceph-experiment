#!/bin/bash
# testes.sh - roda os experimentos E1..E8 (secao 6.3) e E9-C (deteccao de falhas lentas)
# do Tema 2 (Ceph). Requer: Linux/WSL (date +%s.%N), docker, awk, cluster ja no ar (docker compose up -d).
#
# Uso:
#   ./testes.sh e1|e2|e3|e4|e5|e6|e7|e7b|e8|e9c   roda um experimento
#   ./testes.sh basicos                            roda E1..E8 em sequencia (sem e7b)
#   ./testes.sh reset                              religa tudo, reconecta rede, limpa config do E9-C
#
# Variaveis opcionais:
#   REPS=5                  repeticoes das medicoes (E3, E7, E8)
#   E9C_REPS=5              repeticoes por valor de grace no E9-C
#   E9C_GRACES="20"         lista de osd_heartbeat_grace a testar (ex.: "20 10 40")
#   E9C_OUT=1               1 = mede tambem o tempo ate "out" (+120 s por repeticao); 0 = so "down"
#
# Evidencias: ./evidencias/<experimento>.txt
# IMPORTANTE: a PREVISAO de cada experimento deve ser escrita pela equipe ANTES de rodar.

set -u
REPS=${REPS:-5}
E9C_REPS=${E9C_REPS:-5}
E9C_GRACES=${E9C_GRACES:-20}
E9C_OUT=${E9C_OUT:-1}
POOL=sd
NODES="ceph1 ceph2 ceph3"
EVID=./evidencias
mkdir -p "$EVID"

# ------------------------------------------------------------------ utilidades
now()     { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }
stats()   { awk '{s+=$1; ss+=$1*$1; n++} END{ if(n>0){m=s/n; v=(n>1)?(ss-n*m*m)/(n-1):0; if(v<0)v=0;
            printf "n=%d  media=%.3f  desvio=%.3f\n", n, m, sqrt(v)} }'; }
titulo()  { echo; echo "=================================================================="; echo "$*"; echo "=================================================================="; }
ip_of()   { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n 's/^NODE_IP=//p'; }
net_of()  { docker inspect ceph1 -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'; }

# primeiro no que esta rodando (nao parado/pausado), opcionalmente excluindo um
any_node() {
  local ex="${1:-}" n st
  for n in $NODES; do
    [ "$n" = "$ex" ] && continue
    st=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null)
    [ "$st" = "running" ] && { echo "$n"; return; }
  done
  echo ceph1
}
cc() { docker exec "$(any_node)" "$@"; }       # roda comando em algum no vivo

# cluster saudavel: 3 mons em quorum, 3 OSDs up, PGs active+clean sem estados anormais
saudavel() {
  local n out; n=$(any_node)
  out=$(docker exec "$n" timeout 10 ceph -s 2>/dev/null) || return 1
  echo "$out" | grep -q 'quorum ceph1,ceph2,ceph3' || return 1
  echo "$out" | grep -q '3 osds: 3 up' || return 1
  echo "$out" | grep -q 'active+clean' || return 1
  echo "$out" | grep -Eq 'degraded|undersized|peering|recovering|backfill|remapped|stale|inactive|unknown|down' && return 1
  return 0
}
esperar_saudavel() {          # $1 = timeout em s (padrao 300). Imprime o tempo gasto.
  local t0 lim=${1:-300}; t0=$(now)
  until saudavel; do
    [ "$(elapsed "$t0" "$(now)" | cut -d. -f1)" -ge "$lim" ] && { echo "TIMEOUT"; return 1; }
    sleep 1
  done
  elapsed "$t0" "$(now)"
}
garantir_pool() {
  docker exec ceph1 ceph osd pool create $POOL 32 >/dev/null 2>&1
  docker exec ceph1 ceph osd pool application enable $POOL rados >/dev/null 2>&1
}
rc_txt() { [ "$1" -eq 0 ] && echo OK || { [ "$1" -eq 124 ] && echo "BLOQUEADO(timeout)" || echo "ERRO(rc=$1)"; }; }

# ------------------------------------------------------------------ E1
e1() {
  titulo "E1 - Subida e topologia"
  garantir_pool
  echo "--- docker ps"; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo "--- enderecos"; for n in $NODES; do echo "$n  $(ip_of $n)"; done
  echo "--- ceph -s";                 docker exec ceph1 ceph -s
  echo "--- ceph osd tree (um host por conteiner)"; docker exec ceph1 ceph osd tree
  echo "--- ceph quorum_status";     docker exec ceph1 ceph quorum_status -f json-pretty
  echo "--- ceph mon stat";          docker exec ceph1 ceph mon stat
  echo "--- daemons por conteiner"
  for n in $NODES; do echo "[$n]"; docker exec "$n" sh -c 'ps -eo args | grep -E "ceph-(mon|osd|mgr)" | grep -v grep | cut -c1-90'; done
  echo "--- pool"; docker exec ceph1 ceph osd pool ls detail
}

# ------------------------------------------------------------------ E2
e2() {
  titulo "E2 - Caminho de uma operacao"
  garantir_pool
  docker exec ceph1 sh -c 'echo "ola SD" > /tmp/a && rados -p sd put obj1 /tmp/a' && echo "put obj1 OK"
  echo "--- ceph osd map (PG, up/acting, primario)"
  docker exec ceph1 ceph osd map $POOL obj1
  local p; p=$(docker exec ceph1 ceph osd map $POOL obj1 -f json | grep -o '"acting_primary":[0-9]*' | cut -d: -f2)
  echo "--- OSD primario = osd.$p"; docker exec ceph1 ceph osd find "$p"
  echo "--- conjunto acting (hosts)"
  docker exec ceph1 ceph osd map $POOL obj1 -f json | grep -o '"acting":\[[0-9,]*\]'
  echo "--- leitura a partir de outro no (cliente calcula via CRUSH, sem servidor de metadados)"
  docker exec ceph3 rados -p $POOL get obj1 -
  echo "--- crushmap/osdmap epoca que o cliente usou"
  docker exec ceph1 ceph osd dump | head -1
}

# ------------------------------------------------------------------ E3
e3() {
  titulo "E3 - Replicacao (objetos pequenos: -b 4096)"
  garantir_pool
  echo "--- escrever no ceph1 e ler no ceph3"
  docker exec ceph1 sh -c 'echo "replicado" > /tmp/a && rados -p sd put e3obj /tmp/a'
  docker exec ceph3 rados -p $POOL get e3obj -
  echo; echo "--- tempo de propagacao (put no ceph1 -> visivel no ceph3), $REPS medicoes (inclui overhead do docker exec)"
  local i v t0 t1 r tempos=""
  for i in $(seq 1 "$REPS"); do
    v="v$i-$RANDOM"
    t0=$(now)
    docker exec ceph1 sh -c "echo $v > /tmp/p && rados -p sd put prop /tmp/p"
    until [ "$(docker exec ceph3 rados -p $POOL get prop - 2>/dev/null)" = "$v" ]; do sleep 0.05; done
    t1=$(now); r=$(elapsed "$t0" "$t1"); echo "  rep $i: $r s"; tempos="$tempos$r\n"
  done
  printf "$tempos" | stats
  echo; echo "--- rados bench ($REPS execucoes de 10 s; write 4 KB, depois seq 5 s)"
  local w_iops="" w_lat="" s_iops="" s_lat="" out
  for i in $(seq 1 "$REPS"); do
    out=$(docker exec ceph1 rados bench -p $POOL 10 write -b 4096 -t 4 --no-cleanup 2>&1)
    w_iops="$w_iops$(echo "$out" | awk '/^Average IOPS/{print $3}')\n"
    w_lat="$w_lat$(echo "$out" | awk '/^Average Latency\(s\)/{print $3}')\n"
    out=$(docker exec ceph1 rados bench -p $POOL 5 seq -t 4 2>&1)
    s_iops="$s_iops$(echo "$out" | awk '/^Average IOPS/{print $3}')\n"
    s_lat="$s_lat$(echo "$out" | awk '/^Average Latency\(s\)/{print $3}')\n"
    docker exec ceph1 rados -p $POOL cleanup >/dev/null 2>&1
    echo "  execucao $i concluida"
  done
  echo "write IOPS:        $(printf "$w_iops" | stats)"
  echo "write lat media(s): $(printf "$w_lat" | stats)"
  echo "seq   IOPS:        $(printf "$s_iops" | stats)"
  echo "seq   lat media(s): $(printf "$s_lat" | stats)"
}

# ------------------------------------------------------------------ E4
e4() {
  titulo "E4 - Consistencia"
  garantir_pool
  echo "--- (a) sequencial: escreve i no ceph1; ao ACK, le no ceph2 (50 iteracoes)"
  local i v stale=0
  for i in $(seq 1 50); do
    docker exec ceph1 sh -c "echo $i | rados -p $POOL put cnt -"
    v=$(docker exec ceph2 rados -p $POOL get cnt - 2>/dev/null)
    [ "$v" = "$i" ] || { stale=$((stale+1)); echo "  STALE: escrito=$i lido=$v"; }
  done
  echo "leituras desatualizadas apos ACK: $stale de 50"

  echo; echo "--- (b) concorrente: escritor (ceph1) 1001..1080 x leitor (ceph2) em laco"
  docker exec ceph1 bash -c 'for i in $(seq 1001 1080); do echo $i | rados -p sd put cnt -; done' &
  docker exec ceph2 bash -c 'for k in $(seq 1 120); do rados -p sd get cnt - 2>/dev/null; done' > "$EVID/e4_leituras_raw.txt" &
  wait
  echo "amostra de leituras (primeiras/ultimas 5):"; head -5 "$EVID/e4_leituras_raw.txt"; echo ...; tail -5 "$EVID/e4_leituras_raw.txt"
  awk 'NF{ if(NR>1 && $1+0 < prev) dec++; prev=$1+0; n++ } END{printf "leituras=%d  regressoes de valor (leu valor mais antigo que o anterior)=%d\n", n, dec+0}' "$EVID/e4_leituras_raw.txt"
  echo "Esperado: 0 leituras desatualizadas (escrita so e confirmada apos gravar nas replicas; leitura vai ao primario do PG)."
}

# ------------------------------------------------------------------ E5
linha_estado() {   # $1 = rotulo; mede leitura e escrita a partir do ceph1
  local rl rw
  docker exec ceph1 timeout 15 rados -p $POOL get obj1 - >/dev/null 2>&1; rl=$?
  docker exec ceph1 sh -c "echo x > /tmp/a" ; docker exec ceph1 timeout 15 rados -p $POOL put e5obj /tmp/a >/dev/null 2>&1; rw=$?
  printf "| %-28s | %-20s | %-20s |\n" "$1" "$(rc_txt $rl)" "$(rc_txt $rw)"
}
e5() {
  titulo "E5 - Falha e quorum (leituras/escritas disparadas do ceph1; timeout 15 s)"
  garantir_pool
  docker exec ceph1 sh -c 'echo "ola SD" > /tmp/a && rados -p sd put obj1 /tmp/a'
  printf "| %-28s | %-20s | %-20s |\n" "nos ativos" "leitura" "escrita"
  linha_estado "3 (ceph1,2,3)"
  echo; echo ">>> docker stop ceph3 (minoria)"; docker stop -t 5 ceph3 >/dev/null
  sleep 30
  docker exec ceph1 timeout 15 ceph -s || echo "ceph -s sem resposta"
  echo; printf "| %-28s | %-20s | %-20s |\n" "nos ativos" "leitura" "escrita"
  linha_estado "2 (ceph1,2)"
  echo; echo ">>> docker stop ceph2 (maioria)"; docker stop -t 5 ceph2 >/dev/null
  sleep 30
  docker exec ceph1 timeout 15 ceph -s || echo "sem quorum de monitores"
  echo; printf "| %-28s | %-20s | %-20s |\n" "nos ativos" "leitura" "escrita"
  linha_estado "1 (ceph1)"
  echo; echo ">>> restaurando"; docker start ceph2 ceph3 >/dev/null
  echo "tempo ate cluster saudavel: $(esperar_saudavel) s"
  echo "(relacione size=3/min_size=2 com quorum de escrita: 2 de 3 escrevem; 1 de 3 bloqueia)"
}

# ------------------------------------------------------------------ E6
e6() {
  titulo "E6 - Particao de rede (isolar ceph3)"
  garantir_pool
  local NET IP3 t0 id3; NET=$(net_of); IP3=$(ip_of ceph3)
  id3=$(docker exec ceph3 cut -d' ' -f1 /var/lib/ceph/osd/.node-osd)
  echo "rede=$NET  ceph3=$IP3  osd.$id3"
  docker exec ceph1 sh -c 'echo "particao" > /tmp/a'
  echo ">>> docker network disconnect $NET ceph3"
  docker network disconnect "$NET" ceph3; t0=$(now)
  until docker exec ceph1 ceph osd dump 2>/dev/null | grep "^osd.$id3 " | grep -q ' down '; do sleep 1; done
  echo "osd.$id3 marcado DOWN apos $(elapsed "$t0" "$(now)") s"
  echo; echo "--- LADO MAJORITARIO (ceph1: mons 1 e 2)"
  docker exec ceph1 timeout 15 ceph -s
  docker exec ceph1 timeout 15 rados -p $POOL put p6 /tmp/a; echo "put rc=$? ($(rc_txt $?))"
  docker exec ceph1 timeout 15 rados -p $POOL get p6 -;       echo "get rc=$?"
  echo; echo "--- LADO MINORITARIO (cliente dentro do ceph3)"
  docker exec ceph3 timeout 15 ceph -s;                          echo "ceph -s rc=$? (124 = sem quorum)"
  docker exec ceph3 sh -c 'echo "minoria" > /tmp/m'
  docker exec ceph3 timeout 15 rados -p $POOL put p6m /tmp/m;   echo "put rc=$?"
  docker exec ceph3 timeout 15 rados -p $POOL get obj1 -;        echo "get rc=$?"
  echo; echo ">>> docker network connect --ip $IP3 $NET ceph3"
  docker network connect --ip "$IP3" "$NET" ceph3
  echo "tempo ate cluster saudavel: $(esperar_saudavel) s"
  echo "leitura de p6 a partir do ceph3 apos reconexao: $(docker exec ceph3 rados -p $POOL get p6 - 2>&1)"
  echo "Conclusao esperada: lado minoritario bloqueia (C > A); majoritario segue."
}

# ------------------------------------------------------------------ E7
e7() {
  titulo "E7 - Recuperacao (stop ceph3, escreve, start; $REPS repeticoes)"
  garantir_pool
  local i t0 tempos=""
  for i in $(seq 1 "$REPS"); do
    docker stop -t 5 ceph3 >/dev/null
    docker exec ceph1 bash -c 'echo dado > /tmp/a; for j in $(seq 1 50); do timeout 60 rados -p sd put rec$j /tmp/a; done'
    docker start ceph3 >/dev/null; t0=$(now)
    local r; r=$(esperar_saudavel); echo "  rep $i: ate HEALTH saudavel = $r s"; tempos="$tempos$r\n"
  done
  printf "$tempos" | stats
  echo; echo "--- logs de sincronizacao do ceph3 (ultimas linhas com pg/peering/recovery)"
  docker logs ceph3 2>&1 | grep -Ei 'peering|recover|backfill|active' | tail -15
  echo; echo "--- estado final identico nas replicas (hash da lista de objetos lida em cada no)"
  for n in $NODES; do echo "$n: $(docker exec $n rados -p $POOL ls | sort | md5sum)"; done
  docker exec ceph1 ceph pg stat
}
e7b() {
  titulo "E7b - down x out (no parado > mon_osd_down_out_interval=120 s)"
  garantir_pool
  local t0; docker stop -t 5 ceph3 >/dev/null; t0=$(now)
  local id3; id3=$(docker exec ceph1 cut -d' ' -f1 /var/lib/ceph/osd/.node-osd 2>/dev/null)
  until docker exec ceph1 ceph osd dump 2>/dev/null | grep -E '^osd\.[0-9]+ ' | grep -q ' down '; do sleep 1; done
  echo "OSD marcado DOWN apos $(elapsed "$t0" "$(now)") s"; docker exec ceph1 ceph osd tree
  until docker exec ceph1 ceph osd dump 2>/dev/null | grep -E '^osd\.[0-9]+ ' | grep -q ' out '; do sleep 2; [ "$(elapsed "$t0" "$(now)" | cut -d. -f1)" -gt 400 ] && break; done
  echo "OSD marcado OUT apos $(elapsed "$t0" "$(now)") s"
  sleep 5; docker exec ceph1 ceph -s; docker exec ceph1 ceph osd tree
  echo ">>> religando"; docker start ceph3 >/dev/null
  echo "tempo ate cluster saudavel: $(esperar_saudavel 600) s"
}

# ------------------------------------------------------------------ E8
lider()  { docker exec "$1" ceph quorum_status -f json 2>/dev/null | grep -o '"quorum_leader_name":"[^"]*"' | cut -d'"' -f4; }
epocaq() { docker exec "$1" ceph quorum_status -f json 2>/dev/null | grep -o '"election_epoch":[0-9]*' | cut -d: -f2; }
e8() {
  titulo "E8 - Coordenacao e ordem (lider dos MONs; $REPS repeticoes)"
  garantir_pool
  local i L0 E0 O0 other t0 L1 E1 O1 tempos=""
  for i in $(seq 1 "$REPS"); do
    L0=$(lider ceph1); E0=$(epocaq ceph1); O0=$(docker exec ceph1 ceph osd dump | head -1)
    [ "$i" = 1 ] && { echo "--- antes: lider=$L0 election_epoch=$E0"; echo "$O0"; docker exec ceph1 ceph osd map $POOL obj1; }
    other=$(any_node "$L0")
    docker stop -t 5 "$L0" >/dev/null; t0=$(now)
    while :; do L1=$(lider "$other"); [ -n "$L1" ] && [ "$L1" != "$L0" ] && break; sleep 0.5; done
    local r; r=$(elapsed "$t0" "$(now)")
    E1=$(epocaq "$other")
    until docker exec "$other" ceph osd dump 2>/dev/null | grep -E '^osd\.[0-9]+ ' | grep -q ' down '; do sleep 1; done
    O1=$(docker exec "$other" ceph osd dump | head -1)
    echo "rep $i: lider $L0 -> $L1 em $r s | election_epoch $E0 -> $E1 | $O0 -> $O1"
    tempos="$tempos$r\n"
    [ "$i" = 1 ] && { docker exec "$other" ceph osd map $POOL obj1; docker exec "$other" ceph mon stat; }
    docker start "$L0" >/dev/null
    esperar_saudavel >/dev/null
  done
  echo "tempo de eleicao dos MONs: $(printf "$tempos" | stats)"
  echo "OSD primario do PG tambem coordena as escritas daquele PG (ver 'ceph osd map' acima)."
}

# ------------------------------------------------------------------ E9-C
e9c() {
  titulo "E9-C - Deteccao de falhas lentas (docker pause ceph3)"
  garantir_pool
  local G i t0 id3 r_down r_out tab_d tab_o
  id3=$(docker exec ceph3 cut -d' ' -f1 /var/lib/ceph/osd/.node-osd)
  echo "osd alvo: osd.$id3 (ceph3) | reps=$E9C_REPS | graces=[$E9C_GRACES] | medir out=$E9C_OUT"
  echo "mon_osd_down_out_interval atual: $(docker exec ceph1 ceph config get mon mon_osd_down_out_interval 2>/dev/null) (ceph.conf pode sobrepor: esperado 120)"
  for G in $E9C_GRACES; do
    docker exec ceph1 ceph config set global osd_heartbeat_grace "$G"
    sleep 5
    echo; echo "##### osd_heartbeat_grace=$G"
    tab_d=""; tab_o=""
    for i in $(seq 1 "$E9C_REPS"); do
      docker pause ceph3 >/dev/null; t0=$(now)
      until docker exec ceph1 ceph osd dump 2>/dev/null | grep "^osd.$id3 " | grep -q ' down '; do sleep 0.5
        [ "$(elapsed "$t0" "$(now)" | cut -d. -f1)" -gt 300 ] && break; done
      r_down=$(elapsed "$t0" "$(now)")
      if [ "$E9C_OUT" = "1" ]; then
        until docker exec ceph1 ceph osd dump 2>/dev/null | grep "^osd.$id3 " | grep -q ' out '; do sleep 1
          [ "$(elapsed "$t0" "$(now)" | cut -d. -f1)" -gt 400 ] && break; done
        r_out=$(elapsed "$t0" "$(now)")
      else r_out="-"; fi
      docker unpause ceph3 >/dev/null
      echo "  rep $i: down=${r_down}s  out=${r_out}s"
      tab_d="$tab_d$r_down\n"; [ "$r_out" != "-" ] && tab_o="$tab_o$r_out\n"
      echo "    recuperando: $(esperar_saudavel 600) s"
    done
    echo "  grace=$G  tempo ate DOWN: $(printf "$tab_d" | stats)"
    [ -n "$tab_o" ] && echo "  grace=$G  tempo ate OUT:  $(printf "$tab_o" | stats)"
  done
  docker exec ceph1 ceph config rm global osd_heartbeat_grace
  echo; echo "Discussao: grace menor = deteccao rapida, mais falsos positivos (pausas de GC/IO viram 'down'); grace maior = o inverso."
}

# ------------------------------------------------------------------ reset
reset() {
  local NET n; NET=$(net_of)
  for n in $NODES; do docker unpause "$n" >/dev/null 2>&1; docker start "$n" >/dev/null 2>&1
    docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$n" | grep -q "$NET" \
      || docker network connect --ip "$(ip_of $n)" "$NET" "$n"; done
  docker exec ceph1 ceph config rm global osd_heartbeat_grace >/dev/null 2>&1
  echo "aguardando cluster saudavel..."; echo "ok em $(esperar_saudavel 600) s"
}

# ------------------------------------------------------------------ despacho
run() { local nome=$1; shift; "$nome" 2>&1 | tee "$EVID/$nome.txt"; }
case "${1:-}" in
  e1|e2|e3|e4|e5|e6|e7|e7b|e8|e9c|reset) run "$1" ;;
  basicos) for x in e1 e2 e3 e4 e5 e6 e7 e8; do run $x; done ;;
  *) sed -n '2,19p' "$0"; exit 1 ;;
esac