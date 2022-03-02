#!/usr/bin/env bash

## This script requires the following Debian packages:
#
# tor tor-geoipdb obfs4proxy fteproxy gawk bc sudo iptables coreutils 
# procps iproute2 sed grep

HERE=`realpath $0`
HERE=`dirname $HERE`
SUFFIX="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
DATADIR="/dev/shm/tor4vpn-${SUFFIX}"
  if [ -d "${DATADIR}" ]; then
    while [ -d "${DATADIR}" ]; do
      SUFFIX="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
      DATADIR="/dev/shm/tor4vpn-${SUFFIX}"
    done
  fi
NON_LOCAL_BIND_STATE_IPV4="$(/usr/sbin/sysctl -a | grep net.ipv4.ip_nonlocal_bind | awk '{ print $3 }')"
NON_LOCAL_BIND_STATE_IPV6="$(/usr/sbin/sysctl -a | grep net.ipv6.ip_nonlocal_bind | awk '{ print $3 }')"
IFACE="$(ip route get 8.8.8.8 2>/dev/null | grep 'dev' | awk '{ print $5 }')"
ROUTE_IPV4="$(ip route show | grep "default" | awk '{ print $3 }')"
ROUTE_IPV6="$(ip -6 route show | grep "default" | awk '{ print $3 }')"
RP_FILTER_STATE_IFACE="$(/usr/sbin/sysctl -a | grep net.ipv4.conf.${IFACE}.rp_filter | awk '{ print $3 }')"
RP_FILTER_STATE_ALL="$(/usr/sbin/sysctl -a | grep net.ipv4.conf.all.rp_filter | awk '{ print $3 }')"
TABLE_NAME="tor4vpn${SUFFIX}"
FW_MARK="$((RANDOM%2147483646 + 1))"
TABLE_NUMBER="$((RANDOM%251 + 1))"
  if [ "$(cat /etc/iproute2/rt_tables | grep ${TABLE_NUMBER})" ]; then
    while [ "$(cat /etc/iproute2/rt_tables | grep ${TABLE_NUMBER})" ]; do
      TABLE_NUMBER="$((RANDOM%251 + 1))"
    done
  fi
CGROUP_BASE="/sys/fs/cgroup"
SUDO_BIN="$(command -v sudo)"
TORDIR="${DATADIR}/tor"
TOR_CONTROL_PASSWD="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24)"
TOR_OPTS=""

pause_and_exit() {
echo "Digite Q para sair"
read -r EXIT
  if [ ! "${EXIT}" = "Q" ]; then
    pause_and_exit
  else
    sleep 1
  fi
}

#=======================================================================

  if [[ $EUID -ne 0 ]]; then
    echo "Este script deve ser executado como administtrador (root)!"
    exit 1
  fi

echo 'Digite o executável Tor para carregar: [ Enter = AUTOMÁTICO ]'
read -r TORBIN
  if [ ! "${TORBIN}" ]; then
    TORBIN="$(command -v tor)"
    command -v ${TORBIN} &>/dev/null || exit 1
  fi
command -v ${TORBIN} &>/dev/null || exit 1

echo 'Deseja habilitar IPv6? [y = SIM]'
read -r IPV6_CHOOSE

echo 'Deseja usar Bridges? [y = SIM]'
read -r CHOOSE_BRIDGES
  if [ ! "${CHOOSE_BRIDGES}" ]; then
    echo 'Usar um proxy externo para conectar o Tor? [y = SIM]'
    read -r USE_PROXY
      if [ "${USE_PROXY}" = "y" ]; then
        echo 'Selecione um tipo de proxy: [ h = https/http | s4 = SOCKS4 | s5 = SOCKS5 ]'
        read -r PROXY_TYPE_CHOOSE
          case ${PROXY_TYPE_CHOOSE} in
            h)
              echo "Digite o endereço com a porta do proxy no formato endereço:porta : [ Entre [colchetes] se for IPv6 ]"
              read -r PROXY_ADDRESS
                if [ ! "${PROXY_ADDRESS}" ]; then
                  exit 1
                fi
              TOR_OPTS+="\nHTTPSProxy ${PROXY_ADDRESS}"
              echo "Digite o usuário:senha do proxy: [ ENTER = Sem autenticação ]"
              read -r HTTPS_PROXY_AUTH
                if [ "${HTTPS_PROXY_AUTH}" ]; then
                  TOR_OPTS+="\nHTTPSProxyAuthenticator ${HTTPS_PROXY_AUTH}"
                fi
              shift
            ;;
            s4)
              echo "Digite o endereço com a porta do proxy no formato endereço:porta : [ Entre [colchetes] se for IPv6 ]"
              read -r PROXY_ADDRESS
                if [ ! "${PROXY_ADDRESS}" ]; then
                  exit 1
                fi
              TOR_OPTS+="\nSocks4Proxy ${PROXY_ADDRESS}"
              shift
            ;;
            s5)
              echo "Digite o endereço com a porta do proxy no formato endereço:porta : [ Entre [colchetes] se for IPv6 ]"
              read -r PROXY_ADDRESS
                if [ ! "${PROXY_ADDRESS}" ]; then
                  exit 1
                fi
              TOR_OPTS+="\nSocks5Proxy ${PROXY_ADDRESS}"
              echo "Digite o usuário (login) do proxy:"
              read -r SOCKS5_PROXY_USERNAME
                if [ "${SOCKS5_PROXY_USERNAME}" ]; then
                  echo "Digite a senha do proxy:"
                  read -r SOCKS5_PROXY_PASSWORD
                    if [ ! "${SOCKS5_PROXY_PASSWORD}" ]; then
                      exit 1
                    fi
                  TOR_OPTS+="\nSocks5ProxyUsername ${SOCKS5_PROXY_USERNAME}\nSocks5ProxyPassword ${SOCKS5_PROXY_PASSWORD}"
                fi
              shift
            ;;
            *)
              exit 1
            ;;
          esac
      fi
  fi
 
echo 'Digite o endereço de escuta para o Tor: [ ENTER = 127.0.0.1 ]'
read -r TOR_SOCKS_BIND
  if [ ! "${TOR_SOCKS_BIND}" ]; then
    TOR_SOCKS_BIND="127.0.0.1"
  fi

echo 'Digite a porta de escuta para o Tor: [ ENTER = 8001 ]'
read -r TOR_SOCKS_PORT
  if [ ! "${TOR_SOCKS_PORT}" ]; then
    TOR_SOCKS_PORT="8001"
  fi

echo 'Selecione o usuário para carregar o Tor: [ ENTER = root ]'
read -r TOR_USER
  if [ ! "${TOR_USER}" ]; then
    TOR_USER="${USER}"
  fi

#=======================================================================

  if [ ! "${IFACE}" ]; then
    echo "A Internet não está conectada."
    exit 1
  fi

  if [ ! "${ROUTE_IPV4}" ]; then
    echo "Não há rota IPv4 para a Internet."
    exit 1
  fi
  
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    if [ ! "${ROUTE_IPV6}" ]; then
      echo "Não há rota IPv6 para a Internet."
      exit 1
    fi
  fi

#=======================================================================

mkdir -p ${DATADIR}

  if [ ! -d "/var/lib/tor" ]; then
    mkdir -p ${TORDIR}/tor
  else
    mkdir -p ${TORDIR}/tor
    cp -d -R /var/lib/tor/* ${DATADIR}/tor/
      if [ -f ${DATADIR}/tor/lock ]; then
        rm ${DATADIR}/tor/lock
      fi
    chmod -R 700 ${DATADIR}/tor/
  fi

chown -R ${TOR_USER}:${TOR_USER} ${DATADIR}/

echo -n | tee ${DATADIR}/torrc
  if [ ! "${IPV6_CHOOSE}" = "y" ]; then
    echo "# Options for IPv4 client
      SOCKSPort ${TOR_SOCKS_BIND}:${TOR_SOCKS_PORT}
      HTTPTunnelPort ${TOR_SOCKS_BIND}:$((${TOR_SOCKS_PORT} + 79))
      SOCKSPort unix:${DATADIR}/ssocket WorldWritable
      " >> ${DATADIR}/torrc
  else
    echo "# Options for IPv6 client
      SOCKSPort ${TOR_SOCKS_BIND}:${TOR_SOCKS_PORT} IPv6Traffic PreferIPv6
      HTTPTunnelPort ${TOR_SOCKS_BIND}:$((${TOR_SOCKS_PORT} + 79)) IPv6Traffic PreferIPv6
      SOCKSPort unix:${DATADIR}/ssocket IPv6Traffic PreferIPv6 WorldWritable
      ClientUseIPv6 1
      ClientPreferIPv6ORPort 1" >> ${DATADIR}/torrc
  fi
echo "ControlPort ${TOR_SOCKS_BIND}:$((${TOR_SOCKS_PORT} + 1))
ControlPort unix:${DATADIR}/csocket WorldWritable
ClientUseIPv4 1
DataDirectory ${TORDIR}
RunAsDaemon 1
GeoIPFile /usr/share/tor/geoip
GeoIPv6File /usr/share/tor/geoip6
ExitNodes {at},{be},{bg},{ch},{cz},{cy},{de},{is},{jp},{lu},{nl},{no},{pa},{ro},{sc},{sk},{si},{ua},{vg}
ExcludeNodes {??},{br}
ClientOnly 1
StrictNodes 1
EnforceDistinctSubnets 1
ConnectionPadding 1
PidFile ${DATADIR}/torpid
" >> ${DATADIR}/torrc
  if [ ! "${USE_BRIDGES}" = "y" ]; then
    echo "    EntryNodes {at},{be},{bg},{ch},{cz},{cy},{de},{is},{jp},{lu},{nl},{no},{pa},{ro},{sc},{sk},{si},{ua},{vg}
    UseEntryGuards 1
    NumEntryGuards 30
    " >> ${DATADIR}/torrc
      if [ "${USE_PROXY}" = "y" ]; then
        echo -e "${TOR_OPTS}" >> ${DATADIR}/torrc
      fi
  else
    if [ "$(command -v obfs4proxy)" ]; then
      echo "ClientTransportPlugin obfs2,obfs3,obfs4,scramblesuit exec $(command -v obfs4proxy)" >> ${DATADIR}/torrc
    fi
    if [ "$(command -v fteproxy)" ]; then
      echo "ClientTransportPlugin fte exec $(command -v fteproxy) --managed" >> ${DATADIR}/torrc
    fi
    cat --squeeze-blank ${HERE}/tor-bridges.list | shuf -n 20 | while read line;
      do
        echo "Bridge ${line}" >> ${DATADIR}/torrc
      done
    echo "UseBridges 1" >> ${DATADIR}/torrc
  fi
  if [ "${PROXY_TYPE_CHOOSE}" = "h" ]; then
    echo "FascistFirewall 1" >> ${DATADIR}/torrc
  fi

echo "HashedControlPassword $(${TORBIN} --quiet --hash-password ${TOR_CONTROL_PASSWD})" >> ${DATADIR}/torrc

chown ${TOR_USER}:${TOR_USER} ${DATADIR}/torrc

#=======================================================================

sysctl -q -w net.ipv4.ip_nonlocal_bind=1
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    sysctl -q -w net.ipv6.ip_nonlocal_bind=1
  fi

  if [ ! "$(mount -t cgroup2)" ]; then
    CGROUP_BASE="${CGROUP_BASE}/unified"
    UMOUNT_CGROUP="y"
    mkdir -p ${CGROUP_BASE}
    mount -t cgroup2 -o rw,nosuid,nodev,noexec,relatime,nsdelegate cgroup2 ${CGROUP_BASE}
  fi

mkdir ${CGROUP_BASE}/${TABLE_NAME}
echo $$ | tee ${CGROUP_BASE}/${TABLE_NAME}/cgroup.procs > /dev/null
chown -R ${SHELL_USER}:${SHELL_USER} ${CGROUP_BASE}/${TABLE_NAME}

iptables -t mangle -A OUTPUT -m cgroup --path ${TABLE_NAME} -j MARK --set-mark ${FW_MARK}
iptables -t nat -A POSTROUTING -m cgroup --path ${TABLE_NAME} -o ${IFACE} -j MASQUERADE
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip6tables -t mangle -A OUTPUT -m cgroup --path ${TABLE_NAME} -j MARK --set-mark ${FW_MARK}
    ip6tables -t nat -A POSTROUTING -m cgroup --path ${TABLE_NAME} -o ${IFACE} -j MASQUERADE
  fi

echo ${TABLE_NUMBER} ${TABLE_NAME} | tee -a /etc/iproute2/rt_tables > /dev/null

ip rule add fwmark ${FW_MARK} table ${TABLE_NAME}
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip -6 rule add fwmark ${FW_MARK} table ${TABLE_NAME}
  fi

ip route add default via ${ROUTE_IPV4} table ${TABLE_NAME} dev ${IFACE}
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip -6 route add default via ${ROUTE_IPV6} table ${TABLE_NAME} dev ${IFACE}
  fi

sysctl -q -w net.ipv4.conf.${IFACE}.rp_filter=0
sysctl -q -w net.ipv4.conf.all.rp_filter=0

#=======================================================================

echo "================================================================================================================="
echo "| Porta SOCKS5 do Tor em ${TOR_SOCKS_BIND}:${TOR_SOCKS_PORT} e unix:/${DATADIR}/ssocket"
echo "| Porta de proxy HTTP do Tor em ${TOR_SOCKS_BIND}:$((${TOR_SOCKS_PORT} + 79))"
echo "| Porta de controle to Tor em ${TOR_SOCKS_BIND}:$((${TOR_SOCKS_PORT} + 1)) e unix:${DATADIR}/csocket com a senha: ${TOR_CONTROL_PASSWD}"
echo "================================================================================================================="
echo ""

${SUDO_BIN} -u ${TOR_USER} -- ${TORBIN} -f ${DATADIR}/torrc --quiet

pause_and_exit

#=======================================================================

kill -9 "$(cat ${DATADIR}/torpid)"

sleep 5

sysctl -q -w net.ipv4.ip_nonlocal_bind=${NON_LOCAL_BIND_STATE_IPV4}
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    sysctl -q -w net.ipv6.ip_nonlocal_bind=${NON_LOCAL_BIND_STATE_IPV6}
  fi

iptables -t mangle -D OUTPUT -m cgroup --path ${TABLE_NAME} -j MARK --set-mark ${FW_MARK}
iptables -t nat -D POSTROUTING -m cgroup --path ${TABLE_NAME} -o ${IFACE} -j MASQUERADE
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip6tables -t mangle -D OUTPUT -m cgroup --path ${TABLE_NAME} -j MARK --set-mark ${FW_MARK}
    ip6tables -t nat -D POSTROUTING -m cgroup --path ${TABLE_NAME} -o ${IFACE} -j MASQUERADE
  fi

ip route delete default via ${ROUTE_IPV4} table ${TABLE_NAME} dev ${IFACE} 2>/dev/null
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip -6 route delete default via ${ROUTE_IPV6} table ${TABLE_NAME} dev ${IFACE} 2>/dev/null
  fi

ip rule delete fwmark ${FW_MARK} table ${TABLE_NAME}
  if [ "${IPV6_CHOOSE}" = "y" ]; then
    ip -6 rule delete fwmark ${FW_MARK} table ${TABLE_NAME}
  fi

sysctl -q -w net.ipv4.conf.${IFACE}.rp_filter=${RP_FILTER_STATE_IFACE}
sysctl -q -w net.ipv4.conf.all.rp_filter=${RP_FILTER_STATE_ALL}

cat ${CGROUP_BASE}/${TABLE_NAME}/cgroup.procs | while read task_pid; do echo ${task_pid} | tee ${CGROUP_BASE}/cgroup.procs &>/dev/null; done

rmdir ${CGROUP_BASE}/${TABLE_NAME}

  if [ "${UMOUNT_CGROUP}" = "y" ]; then
    umount ${CGROUP_BASE}
    rmdir ${CGROUP_BASE}
  fi

sed -i "/^${TABLE_NUMBER}\s/d" /etc/iproute2/rt_tables

rm -rf ${DATADIR}/*
rm -rf ${DATADIR}
