#!/bin/bash
# AlphaPool node installer: Bitcoin Knots + a DATUM gateway on a server YOU own, mining with AlphaPool.
#
#   sudo bash ap-node.sh --address <your payout address> [--tag "<block name>"] [--yes]
#   bash ap-node.sh --help        all options. README.md explains every step, every file and how to undo it.
#
# Needs Ubuntu 22.04 or 24.04 LTS (x86_64), 4 GB RAM and 80 GB disk. It installs:
#   * Bitcoin Knots 29.4.2.knots20260508 as a pruned node: the node that builds your blocks
#   * AlphaPool's DATUM gateway (release 3.1): makes block templates from YOUR node; your rigs connect to it
#   * AlphaPool's chain snapshot, so the node is ready in well under an hour instead of days
#   * a firewall that keeps your SSH port open, lets rigs and Bitcoin peers in and keeps everything else closed
# Every download is pinned below (https URL + sha256) and checked BEFORE it is used.
#
# AlphaPool gets NO access to this server: no SSH keys, no allowlists, no remote commands, no update channel.
# Your SSH setup is not touched. The optional status heartbeat (only with --node-id and --token) reports sync and
# mining status to your AlphaPool dashboard, never passwords, keys or configs. Turn it off: alphapool-node heartbeat off
#
# Your node, your software: --gateway-* and --knots-* install other builds, `alphapool-node switch` changes them
# later, and re-running this installer never replaces a build you chose or a file you edited by hand.
set -uo pipefail
umask 022
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

AP_VERSION="2026-10-05.2"
INSTALLER_URL="https://xbt.alphapool.tech/node/install.sh"     # what --print-cloud-init fetches (and verifies)

# ==== Pins: AlphaPool's tested software. They change only with a new installer release (= a new sha256 for it). ====
KNOTS_VER="29.4.2.knots20260508"
KNOTS_URL="https://bitcoinknots.org/files/29.x/29.4.2.knots20260508/bitcoin-29.4.2.knots20260508-x86_64-linux-gnu.tar.gz"
KNOTS_SHA256="b59d0445a317e21a03dc29425db3aba79b27d5125230b1a2b1dce62e120827c5"   # SHA256SUMS signed by Luke Dashjr
# AlphaPool's DATUM gateway release 3.1. The tarball's sha256 is checked before it is unpacked, the binary's after.
GW_URL="https://snapshots.alphapool.tech:8444/gw/datum_gateway-r3.1-4e56f553732e.tar.gz"
GW_TAR_SHA256="09fe3762fe1b0bef5873ef06a466ab500e19d01e5836cb9492403cead8a67e72"
GW_SHA256="4e56f553732e981113ffd2abdc8fd59d6c7dbf63fc3bafe579058bda9aaf8aa7"
# Ubuntu 22.04: the same release-3.1 source built natively there (the build above needs glibc 2.38; 22.04 has 2.35).
# Reproducible: gateway/build-gw.sh jammy rebuilds it byte for byte. The installer picks the build by VERSION_ID.
GW_JAMMY_URL="https://snapshots.alphapool.tech:8444/gw/datum_gateway-r3.1-jammy-b601102ba731.tar.gz"
GW_JAMMY_TAR_SHA256="c7cb95ac67a76bf04fbcd38cbc9ba4172fe10c76cb2836c5d5e82144e779767c"
GW_JAMMY_SHA256="b601102ba7314ce0277f3a7acd0a2f7fa97ebdf35f560b93db78a59d4807fcfc"
# Chain snapshot (blocks/ + chainstate/ of a pruned node), served by AlphaPool. Its server admits a few downloads at a
# time; when every slot is taken it answers 503 and the installer waits for a free slot (it never counts as a failure).
# The sha256 is the pin, whatever host serves the file.
SNAP_URL="https://snapshots.alphapool.tech:8444/xbt/xbt-snapshot-20260922T1838Z.tar"
SNAP_SHA256="244411e1c679d20253fba6c87e172d7e2e33c1d9187c743e80e939f309b56dc9"
SNAP_BYTES=15709726720
# assumeutxo fast start (--sync assumeutxo): needs a Knots build whose chainparams know the snapshot's height and a
# published UTXO file. Not published by AlphaPool yet: empty pins mean you pass --utxo-* yourself.
UTXO_URL=""
UTXO_SHA256=""
UTXO_BYTES=0
UTXO_HEIGHT=0

# ==== AlphaPool ====
POOL_HOST="us2.alphapool.tech"
POOL_PORT=28916
POOL_PUBKEY="b831b2d6f1eaedb3da5b9e3702728edea0a32d6ce783a1452b2861c4d1b74d6b4c2ad5461bcf43485a6bac2cedf8da43d51164262ef6bcdb27f2242ada066d29"
HEARTBEAT_URL="https://xbt.alphapool.tech/api/node/heartbeat"
# AlphaPool's payout requirement (not a lock): AlphaPool pays every miner directly in the coinbase transaction of each
# block. This chain's blocks hold at most 800,000 weight units and Knots fills a template up to blockmaxweight minus
# 8,000, so 740000 leaves about 17 KB for that payout list. Above it, a busy mempool can leave too little room and the
# gateway cannot build an AlphaPool job. The installer writes 740000 and warns (never blocks) if you raise it.
PAYOUT_MAX_BLOCKWEIGHT=740000

# ==== Where everything lives (README "Files") ====
U=alphapool
HOME_U=/home/$U
DD=$HOME_U/.bitcoin
BTC_CONF=$DD/bitcoin.conf
GWD=$HOME_U/datum_gateway
GW_BIN=$GWD/datum_gateway
GW_CONF=$GWD/datum_gateway_config.json
ETC=/etc/alphapool
CONF=$ETC/node.conf            # your settings (address, block name, ports, choices)
STATE=$ETC/state               # what the installer installed and wrote (sha256s), so a re-run can tell your edits
REQ=$ETC/request               # one-shot software switch for the next run
TOKEN_FILE=$ETC/heartbeat.token
HB_CONF=$ETC/heartbeat.conf
LIB=/usr/local/lib/alphapool
CLI_BIN=/usr/local/sbin/alphapool-node
LOG=/var/log/alphapool-node.log
DL=/var/tmp/alphapool
RUN=/run/alphapool
UNITS=/etc/systemd/system
INSTALL_UNIT=alphapool-node-install
LOCK=/run/alphapool-node-install.lock
TOTAL_STEPS=9

# ==== test mode: AP_DRY_RUN=1 (refused outside a throwaway container) =================================================
# Skips apt, downloads (AP_DRY_FIXTURES=/dir supplies them by file name), systemd, ufw, iptables, swap and network
# probes; runs every validation and writes every file. Planned commands go to /etc/alphapool/dry-run.plan.
DRY=${AP_DRY_RUN:-0}
PLAN=/var/log/alphapool-dry-run.plan
is_dry(){ [ "$DRY" = 1 ]; }
in_container(){ [ -e /.dockerenv ] || [ -e /run/.containerenv ]; }

# ==== output ===========================================================================================================
WARNINGS=()
PHASE=preflight
say(){ printf '%s\n' "$*"; }
say_t(){ printf '%s  (%s)\n' "$*" "$(date -u +%H:%M:%SZ)"; }   # events with a time stamp: durations are readable
warn(){ printf 'WARNING: %s\n' "$*"; WARNINGS+=("$*"); }
# die CODE MESSAGE: a plain-language error with a code the AlphaPool dashboard explains (README "Error codes").
die(){
  local code=$1; shift
  printf '\nERROR [%s]: %s\n' "$code" "$*"
  if [ "$PHASE" = preflight ]; then
    say "Nothing was changed on this server. Fix the problem above and run the same command again."
    [ "$MODE" = install ] && issue_set "install NOT started [$code]: $* - fix it, then run the install command again"
  else
    say "The install stopped at step ${STEP_N:-?}/$TOTAL_STEPS (${STEP_NAME:-}). Fix the problem above and run the same"
    say "command again (or: alphapool-node repair). It continues where it stopped: downloads resume, chain data is kept."
    rm -f "$ETC/install-in-progress" 2>/dev/null
    printf 'failed %s %s\n' "$code" "$(date -u +%FT%TZ)" > "$ETC/last-result" 2>/dev/null
    issue_set "install FAILED [$code] - log in and run: alphapool-node status"
  fi
  [ "$MODE" = install ] || [ "$MODE" = worker ] && console_note "install FAILED [$code]: $*"
  [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null
  drain
  exit 1
}
STEP_N=0; STEP_NAME=""
step(){
  STEP_N=$1; shift; STEP_NAME="$*"
  printf '\n[%d/%d] %s  (%s)\n' "$STEP_N" "$TOTAL_STEPS" "$STEP_NAME" "$(date -u +%H:%M:%SZ)"
  status_set "step $STEP_N/$TOTAL_STEPS: $STEP_NAME"
  console_note "installing, step $STEP_N/$TOTAL_STEPS: $STEP_NAME"
  [ "$STEP_N" -lt "$TOTAL_STEPS" ] && issue_set "installing (step $STEP_N/$TOTAL_STEPS: $STEP_NAME) - log in and run: alphapool-node status"
  return 0
}
status_set(){ { install -d -m 0755 "$RUN" && printf '%s\n' "$*" > "$RUN/install-status"; } 2>/dev/null; return 0; }
# The provider's web console is how a cloud-init install is watched: short notes go to tty1 (VGA) and ttyS0 (serial).
console_note(){
  is_dry && return 0
  local d
  for d in /dev/tty1 /dev/ttyS0; do
    [ -c "$d" ] && [ -w "$d" ] && timeout 2 bash -c 'printf "\r\n[AlphaPool node] %s\r\n" "$1" > "$2"' _ "$*" "$d" 2>/dev/null
  done
  return 0
}
# /etc/issue.d: the login prompt on the web console shows the install state and, at the end, where rigs connect.
issue_set(){
  [ -d /etc/issue.d ] || mkdir -p /etc/issue.d 2>/dev/null || return 0
  printf 'AlphaPool node: %s\n\n' "${*//\\/}" > /etc/issue.d/alphapool.issue 2>/dev/null || return 0
  is_dry || timeout 5 agetty --reload >/dev/null 2>&1
  return 0
}
run(){ if is_dry; then printf 'DRY: %s\n' "$*" >> "$PLAN"; return 0; fi; "$@"; }   # systemctl/ufw/iptables/swap
run_q(){ if is_dry; then run "$@"; return; fi; local o; o=$("$@" 2>&1) && return 0; printf '%s\n' "$o"; return 1; }   # quiet unless it fails
# The log goes through a process-substituted tee; drain lets it flush the last lines before the script exits.
TEE_PID=""
start_tee(){ exec 3>&1 4>&2; exec > >(tee -a "$LOG") 2>&1; TEE_PID=$!; }
drain(){ [ -n "$TEE_PID" ] || return 0; exec >&- 2>&-; local i; for i in $(seq 1 30); do kill -0 "$TEE_PID" 2>/dev/null || return 0; sleep 0.1; done; }

# ==== small helpers ====================================================================================================
sha_of(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
sha_ok(){ [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
url_ok(){ [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=,@-]*$ ]]; }
rand_hex(){ head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }
gb(){ awk -v b="$1" 'BEGIN{printf "%.1f", b/1e9}'; }
kv_get(){   # FILE KEY -> the value of the last KEY= line (files are never sourced)
  [ -r "$1" ] || return 1
  local line v="" found=1
  while IFS= read -r line || [ -n "$line" ]; do case "$line" in "$2="*) v=${line#*=}; found=0;; esac; done < "$1"
  [ $found -eq 0 ] && printf '%s' "$v"
}
kv_set(){   # FILE KEY VALUE (atomic; values never contain newlines; keeps the file's mode)
  local f=$1 k=$2 v=$3 tmp mode=0644
  [ -e "$f" ] && mode=$(stat -c %a "$f")
  tmp=$(mktemp "$f.XXXXXX") || return 1
  { [ -r "$f" ] && awk -v k="$k=" 'index($0, k) != 1' "$f"; printf '%s=%s\n' "$k" "$v"; } > "$tmp"
  chmod "$mode" "$tmp" && mv -f "$tmp" "$f"
}
# tar_safe: refuse members that could land outside the target: absolute paths, "..", links, devices, fifos, and any
# archive tar cannot list. The listings go to files first: `tar | grep -q` under pipefail reports a SIGPIPE'd tar as a
# failure, which on a long listing would hide the very member grep found.
tar_safe(){
  local l n bad
  l=$(mktemp) && n=$(mktemp) || return 1
  if ! tar -tvf "$1" > "$l" 2>/dev/null || ! tar -tf "$1" > "$n" 2>/dev/null; then rm -f "$l" "$n"; return 1; fi
  bad=$(( $(awk '{print substr($1,1,1)}' "$l" | grep -cv '^[-d]$') + $(grep -cE '(^/|(^|/)\.\.(/|$))' "$n") ))
  rm -f "$l" "$n"
  [ "$bad" -eq 0 ]
}
tar_only_chain(){   # the snapshot may hold blocks/ and chainstate/ only: no wallets, no config
  local n bad
  n=$(mktemp) || return 1
  tar -tf "$1" > "$n" 2>/dev/null || { rm -f "$n"; return 1; }
  bad=$(grep -cvE '^(\./)?(blocks|chainstate)(/|$)' "$n")
  rm -f "$n"
  [ "$bad" -eq 0 ]
}

# ==== input validation (also used by the tests and by --check) =========================================================
# Payout address: what the DATUM gateway can pay. Legacy P2PKH (1...), P2SH (3...), segwit v0 P2WPKH/P2WSH and v1 P2TR
# (bc1...), with the full checksum (base58check / BIP173 bech32 / BIP350 bech32m). Bech32 is normalized to lowercase.
B32=qpzry9x8gf2tvdw0s3jn54khce6mua7l
B58=123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
ADDR_WHY=""
bech32_polymod(){
  local chk=1 v b i
  local -a G=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  for v in "$@"; do
    b=$(( chk >> 25 )); chk=$(( ((chk & 0x1ffffff) << 5) ^ v ))
    for i in 0 1 2 3 4; do (( (b >> i) & 1 )) && chk=$(( chk ^ G[i] )); done
  done
  printf '%s' "$chk"
}
check_segwit(){   # sets NORM_ADDR or ADDR_WHY
  local a=$1 data c pos i n ver acc=0 bits=0 spec plen
  local -a dv=() prog=()
  ADDR_WHY="the payout address is not a valid bech32 mainnet address"
  [ "$a" = "${a,,}" ] || [ "$a" = "${a^^}" ] || return 1
  a=${a,,}
  [ ${#a} -ge 14 ] && [ ${#a} -le 90 ] && [ "${a:0:3}" = bc1 ] || return 1
  data=${a:3}
  for (( i=0; i<${#data}; i++ )); do
    c=${data:i:1}; pos=${B32%%"$c"*}; [ ${#pos} -lt 32 ] || return 1; dv+=("${#pos}")
  done
  [ ${#dv[@]} -ge 7 ] || return 1
  c=$(bech32_polymod 3 3 0 2 3 "${dv[@]}")
  if [ "$c" -eq 1 ]; then spec=bech32; elif [ "$c" -eq $((0x2bc830a3)) ]; then spec=bech32m; else return 1; fi
  n=$(( ${#dv[@]} - 6 )); [ $n -ge 1 ] || return 1
  ver=${dv[0]}
  for (( i=1; i<n; i++ )); do
    acc=$(( (acc << 5) | dv[i] )); bits=$(( bits + 5 ))
    while [ $bits -ge 8 ]; do bits=$(( bits - 8 )); prog+=( $(( (acc >> bits) & 255 )) ); done
    acc=$(( acc & ((1 << bits) - 1) ))
  done
  [ $bits -lt 5 ] && [ $acc -eq 0 ] || return 1
  plen=${#prog[@]}
  [ $plen -ge 2 ] && [ $plen -le 40 ] && [ "$ver" -le 16 ] || return 1
  if [ "$ver" -eq 0 ]; then [ $spec = bech32 ] || return 1; else [ $spec = bech32m ] || return 1; fi
  if ! { { [ "$ver" -eq 0 ] && { [ $plen -eq 20 ] || [ $plen -eq 32 ]; }; } || { [ "$ver" -eq 1 ] && [ $plen -eq 32 ]; }; }; then
    ADDR_WHY="the payout address uses a witness version the gateway cannot pay"; return 1
  fi
  NORM_ADDR=$a
}
hex_to_bin(){ local h=$1 o="" i; for (( i=0; i<${#h}; i+=2 )); do o+="\\x${h:i:2}"; done; printf '%b' "$o"; }
check_base58(){   # sets NORM_ADDR or ADDR_WHY
  local a=$1 i j c pos carry z=0 hex="" hx h1 h2
  local -a by=()
  ADDR_WHY="the payout address is not a valid legacy or P2SH mainnet address"
  for (( i=0; i<${#a}; i++ )); do
    c=${a:i:1}; pos=${B58%%"$c"*}; [ ${#pos} -lt 58 ] || return 1; carry=${#pos}
    for (( j=0; j<${#by[@]}; j++ )); do carry=$(( carry + by[j] * 58 )); by[j]=$(( carry & 255 )); carry=$(( carry >> 8 )); done
    while [ "$carry" -gt 0 ]; do by+=( $(( carry & 255 )) ); carry=$(( carry >> 8 )); done
  done
  while [ "${a:z:1}" = 1 ]; do z=$(( z + 1 )); done
  [ $(( z + ${#by[@]} )) -eq 25 ] || return 1
  for (( i=0; i<z; i++ )); do hex+=00; done
  for (( i=${#by[@]}-1; i>=0; i-- )); do printf -v hx '%02x' "${by[i]}"; hex+=$hx; done
  case "${hex:0:2}" in 00|05) ;; *) return 1;; esac
  h1=$(hex_to_bin "${hex:0:42}" | sha256sum | cut -c1-64)
  h2=$(hex_to_bin "$h1" | sha256sum | cut -c1-8)
  [ "$h2" = "${hex:42:8}" ] || return 1
  NORM_ADDR=$a
}
check_address(){   # $1 -> NORM_ADDR, or ADDR_WHY and status 1
  local a=$1
  NORM_ADDR=""; ADDR_WHY="the payout address is not a mainnet address"
  [ -n "$a" ] && [ ${#a} -le 90 ] && [[ $a =~ ^[A-Za-z0-9]+$ ]] || return 1
  case "${a:0:3}" in [bB][cC]1) check_segwit "$a"; return;; esac
  case "${a:0:1}" in 1|3) check_base58 "$a"; return;; esac
  ADDR_WHY="the payout address must be a mainnet address (1..., 3... or bc1...)"; return 1
}
# Block name: printed after DATUM-AP in the coinbase of every block this node finds: public and permanent.
# 1-16 printable ASCII, not blank, not a reserved name. Names that block explorers attribute to a different pool are
# refused too (they would credit your block to it); that list is kept as sha256 hashes of the names.
TAG_RESERVED=("managed" "datum" "datum-ap" "datum user" "datum gateway" "alphapool" "alpha pool")
TAG_OTHER_LENGTHS="6 7 8 9 10 13"
TAG_OTHER_SHA256=" aba1332a86e4d931efadb6b0a81ca9b9176a3a538abe994e706154b99bfbc938 1727134250b3785bae88c3c8c2af925edb065965226f51818c1caff2f6d48e30
 280b42295be466b74fb6c14fd3bc2396abaa1258b73d5a1682c8899a0bf790b5 56dc1a011eb4606c89e98b2d7e205f38d1daf7ee1a88ac42642e55a99612fbb9
 7a0550bccce738e90be22f4f686e14e088200863504ddddc97484270a14a51d0 55fd5f1bf7cfc8b09681c2b645d81cb2ffbd2261e7b989d930ca80a664f5d88d
 9d012d8c71b0f0f709614a8edb3cc71ef226d373f2694e20e4e41c6f3e8ea789 e5df621b4d60cd06e602b215cba80fa0cd230233764f3cf096d0b4373222b0bb "
TAG_WHY=""
check_tag(){
  local t=$1 low sq trim r L i h
  TAG_WHY=""
  if ! [[ $t =~ ^[\ -~]{1,16}$ ]]; then TAG_WHY="the block name must be 1-16 printable ASCII characters"; return 1; fi
  low=${t,,}; sq=$(printf '%s' "$low" | tr -cd 'a-z0-9')
  trim=${low#"${low%%[! ]*}"}; trim=${trim%"${trim##*[! ]}"}
  [ -n "$trim" ] || { TAG_WHY="the block name must not be blank"; return 1; }
  for r in "${TAG_RESERVED[@]}"; do [ "$trim" = "$r" ] && { TAG_WHY="the block name '$t' is reserved"; return 1; }; done
  [[ $sq == *alphapool* ]] && { TAG_WHY="the block name '$t' is reserved"; return 1; }
  for L in $TAG_OTHER_LENGTHS; do
    for (( i=0; i+L<=${#sq}; i++ )); do
      h=$(printf '%s' "${sq:i:L}" | sha256sum | cut -c1-64)
      case "$TAG_OTHER_SHA256" in *" $h"*)
        TAG_WHY="this block name contains a name that block explorers credit to a different pool; pick another"
        return 1;; esac
    done
  done
}
port_ok(){ [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && case "$1" in 22|7152|8332|8333) false;; esac; }
uuid_ok(){ [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
token_ok(){ [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
host_ok(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }

# ==== arguments ========================================================================================================
usage(){ cat <<'USAGE'
AlphaPool node installer: Bitcoin Knots + a DATUM gateway on your own server (Ubuntu 22.04 or 24.04 LTS, x64).

  sudo bash ap-node.sh --address <payout address> [options]

Your settings
  --address ADDR          payout address (1..., 3... or bc1...). Required the first time.
  --tag "NAME"            block name written into blocks your node finds (1-16 characters). Optional.
  --stratum-port N        port your rigs connect to (default 23334)
  --alias-ports "P Q"     extra ports that lead to the same stratum port (for example "3333 7777"); "none" removes them
  --public-host HOST      name or IP your rigs use, shown in the summary (default: this server's public IPv4)

Status heartbeat to your AlphaPool dashboard (optional; status only, never secrets)
  --node-id UUID          your node id from the dashboard ("My node")
  --token HEX | --token - read the 64-hex token from the command line, or from stdin / a hidden prompt with "-"
  --token-file PATH       read it from a file only root can read (chmod 600)
  --no-heartbeat          turn the heartbeat off

Software (default: AlphaPool's tested Knots 29.4.2 and gateway release 3.1)
  --gateway alphapool                      AlphaPool's gateway build
  --gateway-file PATH                      a gateway binary you built or downloaded
  --gateway-url URL --gateway-sha256 HEX   a gateway release (archive or binary) and its sha256
  --gateway-git URL --gateway-commit HEX   build a DATUM gateway from source at that commit
  --knots alphapool                        AlphaPool's Knots pin
  --knots-url URL --knots-sha256 HEX       another Bitcoin Knots release archive and its sha256
  --knots-dir DIR                          bitcoind + bitcoin-cli you built (DIR or DIR/bin)

Chain data
  --sync snapshot         (default) start from AlphaPool's pinned chain snapshot: ready in well under an hour
  --sync assumeutxo       Knots assumeutxo: needs --utxo-url/--utxo-sha256/--utxo-bytes/--utxo-height and a Knots
                          build that knows that height (see README)
  --sync network          sync everything from the Bitcoin network yourself: takes days on a small server
  --snapshot-url URL      download the same pinned snapshot from a mirror

Behaviour
  --yes                   do not ask questions
  --no-follow             start the install in the background and return (cloud-init uses this)
  --foreground            run in this terminal instead of a background service
  --ssh-port N            your SSH port, if it is not detected (it always stays open)
  --firewall off          leave the firewall alone
  --no-port-check         skip the outside check of the stratum port (it asks ifconfig.co to connect back)
  --repair                run again with the saved settings
  --uninstall [--keep-chain]   remove everything this installer added
  --check                 only validate --address/--tag/--node-id and exit
  --print-cloud-init [--format script|cloud-config] [--installer-url URL]
                          print first-boot user data for your provider that downloads this exact installer,
                          checks its sha256 and runs it with your settings (default format: a #!/bin/bash script,
                          which cloud-init runs once at first boot without touching the provider's own settings)
  --version, --help

Afterwards: alphapool-node status | logs | restart | heartbeat off | switch ... | uninstall
USAGE
}

A_ADDRESS=""; A_TAG=""; A_TAG_SET=0; A_NODE_ID=""; A_TOKEN=""; A_TOKEN_FILE=""; A_NO_HB=0
A_STRATUM=""; A_ALIAS=""; A_ALIAS_SET=0; A_PUBLIC=""; A_SYNC=""; A_SNAP_MIRROR=""
A_UTXO_URL=""; A_UTXO_SHA=""; A_UTXO_BYTES=""; A_UTXO_HEIGHT=""
A_GW=""; A_GW_FILE=""; A_GW_URL=""; A_GW_SHA=""; A_GW_GIT=""; A_GW_COMMIT=""
A_KN=""; A_KN_URL=""; A_KN_SHA=""; A_KN_DIR=""
A_SSH_PORTS=""; A_FIREWALL=""; A_PORTCHECK=""; YES=0; FOLLOW=1; FOREGROUND=0; KEEP_CHAIN=0; RESUMED=0
MODE=install; CI_FORMAT=script; CI_URL=""
parse_args(){
  local o v
  while [ $# -gt 0 ]; do
    o=$1; v=""
    case "$o" in --*=*) v=${o#*=}; o=${o%%=*};; esac
    case "$o" in
      --address|--tag|--node-id|--token|--token-file|--stratum-port|--alias-ports|--public-host|--sync|--snapshot-url|\
      --utxo-url|--utxo-sha256|--utxo-bytes|--utxo-height|--gateway|--gateway-file|--gateway-url|--gateway-sha256|\
      --gateway-git|--gateway-commit|--knots|--knots-url|--knots-sha256|--knots-dir|--ssh-port|--firewall|--format|\
      --installer-url)
        if [ -z "$v" ] && [[ $1 != *=* ]]; then
          [ $# -ge 2 ] || { echo "ERROR [AP-100]: $o needs a value (see --help)"; exit 1; }
          v=$2; shift
        fi;;
    esac
    case "$o" in
      --address) A_ADDRESS=$v;;            --tag) A_TAG=$v; A_TAG_SET=1;;
      --node-id) A_NODE_ID=$v;;            --token) A_TOKEN=$v;;
      --token-file) A_TOKEN_FILE=$v;;      --no-heartbeat) A_NO_HB=1;;
      --stratum-port) A_STRATUM=$v;;       --alias-ports) A_ALIAS=$v; A_ALIAS_SET=1;;
      --public-host) A_PUBLIC=$v;;         --sync) A_SYNC=$v;;
      --snapshot-url) A_SNAP_MIRROR=$v;;
      --utxo-url) A_UTXO_URL=$v;;          --utxo-sha256) A_UTXO_SHA=$v;;
      --utxo-bytes) A_UTXO_BYTES=$v;;      --utxo-height) A_UTXO_HEIGHT=$v;;
      --gateway) A_GW=$v;;                 --gateway-file) A_GW_FILE=$v;;
      --gateway-url) A_GW_URL=$v;;         --gateway-sha256) A_GW_SHA=$v;;
      --gateway-git) A_GW_GIT=$v;;         --gateway-commit) A_GW_COMMIT=$v;;
      --knots) A_KN=$v;;                   --knots-url) A_KN_URL=$v;;
      --knots-sha256) A_KN_SHA=$v;;        --knots-dir) A_KN_DIR=$v;;
      --ssh-port) A_SSH_PORTS="$A_SSH_PORTS $v";;
      --firewall) A_FIREWALL=$v;;          --no-port-check) A_PORTCHECK=off;;
      --yes|-y) YES=1;;                    --no-follow) FOLLOW=0;;
      --foreground) FOREGROUND=1;;         --repair) ;;
      --uninstall) MODE=uninstall;;        --keep-chain) KEEP_CHAIN=1;;
      --check) MODE=check;;                --print-cloud-init) MODE=cloudinit;;
      --format) CI_FORMAT=$v;;             --installer-url) CI_URL=$v;;
      --worker) MODE=worker;;              --resumed) RESUMED=1;;
      --version) MODE=version;;            --help|-h) MODE=help;;
      *) echo "ERROR [AP-100]: unknown option $1 (see --help)"; exit 1;;
    esac
    shift
  done
}

# ==== settings: flags over the saved node.conf, all validated ==========================================================
ADDRESS=""; TAG=""; STRATUM_PORT=23334; ALIAS_PORTS=""; PUBLIC_HOST=""; SYNC_MODE=snapshot; SNAP_FROM=""
FIREWALL=on; PORT_CHECK=on; HEARTBEAT=off; NODE_ID=""; TOKEN=""
load_settings(){
  local v
  [ -r "$CONF" ] || return 0
  v=$(kv_get "$CONF" ADDRESS) && ADDRESS=$v
  v=$(kv_get "$CONF" TAG) && TAG=$v
  v=$(kv_get "$CONF" STRATUM_PORT) && STRATUM_PORT=$v
  v=$(kv_get "$CONF" ALIAS_PORTS) && ALIAS_PORTS=$v
  v=$(kv_get "$CONF" PUBLIC_HOST) && PUBLIC_HOST=$v
  v=$(kv_get "$CONF" SYNC_MODE) && SYNC_MODE=$v
  v=$(kv_get "$CONF" SNAPSHOT_URL) && SNAP_FROM=$v
  v=$(kv_get "$CONF" FIREWALL) && FIREWALL=$v
  v=$(kv_get "$CONF" PORT_CHECK) && PORT_CHECK=$v
  v=$(kv_get "$CONF" HEARTBEAT) && HEARTBEAT=$v
  v=$(kv_get "$CONF" NODE_ID) && NODE_ID=$v
  v=$(kv_get "$CONF" UTXO_URL) && UTXO_URL=$v
  v=$(kv_get "$CONF" UTXO_SHA256) && UTXO_SHA256=$v
  v=$(kv_get "$CONF" UTXO_BYTES) && UTXO_BYTES=$v
  v=$(kv_get "$CONF" UTXO_HEIGHT) && UTXO_HEIGHT=$v
  return 0
}
apply_flags(){
  [ -n "$A_ADDRESS" ] && ADDRESS=$A_ADDRESS
  [ "$A_TAG_SET" = 1 ] && TAG=$A_TAG
  [ -n "$A_STRATUM" ] && STRATUM_PORT=$A_STRATUM
  if [ "$A_ALIAS_SET" = 1 ]; then ALIAS_PORTS=$A_ALIAS; [ "$ALIAS_PORTS" = none ] && ALIAS_PORTS=""; fi
  [ -n "$A_PUBLIC" ] && PUBLIC_HOST=$A_PUBLIC
  [ -n "$A_SYNC" ] && SYNC_MODE=$A_SYNC
  [ -n "$A_SNAP_MIRROR" ] && SNAP_FROM=$A_SNAP_MIRROR
  [ -n "$A_FIREWALL" ] && FIREWALL=$A_FIREWALL
  [ -n "$A_PORTCHECK" ] && PORT_CHECK=$A_PORTCHECK
  [ -n "$A_UTXO_URL" ] && UTXO_URL=$A_UTXO_URL
  [ -n "$A_UTXO_SHA" ] && UTXO_SHA256=$A_UTXO_SHA
  [ -n "$A_UTXO_BYTES" ] && UTXO_BYTES=$A_UTXO_BYTES
  [ -n "$A_UTXO_HEIGHT" ] && UTXO_HEIGHT=$A_UTXO_HEIGHT
  if [ -n "$A_NODE_ID" ]; then NODE_ID=$A_NODE_ID; HEARTBEAT=on; fi
  [ "$A_NO_HB" = 1 ] && HEARTBEAT=off
  return 0
}
read_token(){   # the token never has to sit on the command line: --token -, --token-file, or a hidden prompt
  local t=""
  if [ -n "$A_TOKEN_FILE" ]; then
    [ -f "$A_TOKEN_FILE" ] || die AP-111 "the token file $A_TOKEN_FILE does not exist"
    is_dry || [ "$(stat -c %u "$A_TOKEN_FILE")" = 0 ] || die AP-111 "the token file must belong to root (chown root $A_TOKEN_FILE)"
    [ $(( 0$(stat -c %a "$A_TOKEN_FILE") & 077 )) -eq 0 ] || die AP-111 "the token file must be readable only by root (chmod 600 $A_TOKEN_FILE)"
    IFS= read -r t < "$A_TOKEN_FILE" || [ -n "$t" ] || true
  elif [ "$A_TOKEN" = - ]; then
    if [ -t 0 ]; then
      { IFS= read -rs -p "Heartbeat token (input hidden): " t < /dev/tty; echo; } 2>/dev/tty || true
    else IFS= read -r t || true; fi
  elif [ -n "$A_TOKEN" ]; then
    t=$A_TOKEN
    [ "$MODE" = install ] && warn "the heartbeat token was given on the command line, so it is in your shell history; --token - or --token-file avoid that"
  elif [ -n "$A_NODE_ID" ] && [ -r /dev/tty ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    { IFS= read -rs -p "Heartbeat token for node $A_NODE_ID (input hidden): " t < /dev/tty; echo; } 2>/dev/tty || true
  fi
  t=${t//[[:space:]]/}
  TOKEN=$t
}
validate_settings(){
  check_address "$ADDRESS" || { [ -z "$ADDRESS" ] && die AP-101 "--address is required: the payout address every block pays (1..., 3... or bc1...)"; die AP-101 "$ADDR_WHY: $ADDRESS"; }
  ADDRESS=$NORM_ADDR
  if [ -n "$TAG" ]; then check_tag "$TAG" || die AP-102 "$TAG_WHY"; fi
  port_ok "$STRATUM_PORT" || die AP-103 "--stratum-port $STRATUM_PORT cannot be used (1-65535, not 22, 7152, 8332 or 8333)"
  local p seen=" $STRATUM_PORT "
  for p in $ALIAS_PORTS; do
    { port_ok "$p" && [[ $seen != *" $p "* ]]; } || die AP-103 "alias port $p cannot be used (1-65535, not 22, 7152, 8332, 8333 or a repeat)"
    seen="$seen$p "
  done
  for p in $A_SSH_PORTS; do [[ $p =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die AP-103 "--ssh-port $p is not a port"; done
  [ -z "$PUBLIC_HOST" ] || host_ok "$PUBLIC_HOST" || die AP-104 "--public-host must be a host name or an IPv4 address"
  case "$SYNC_MODE" in snapshot|network|assumeutxo) ;; *) die AP-105 "--sync must be snapshot, assumeutxo or network";; esac
  [ -z "$SNAP_FROM" ] || url_ok "$SNAP_FROM" || die AP-105 "--snapshot-url must be an https URL"
  if [ "$SYNC_MODE" = assumeutxo ]; then
    { url_ok "$UTXO_URL" && sha_ok "$UTXO_SHA256" && [[ $UTXO_BYTES =~ ^[1-9][0-9]{0,14}$ ]] && [[ $UTXO_HEIGHT =~ ^[1-9][0-9]{0,8}$ ]]; } \
      || die AP-105 "--sync assumeutxo needs --utxo-url (https), --utxo-sha256, --utxo-bytes and --utxo-height (no UTXO snapshot is pinned in this installer yet)"
  fi
  case "$FIREWALL" in on|off) ;; *) die AP-106 "--firewall must be on or off";; esac
  case "$PORT_CHECK" in on|off) ;; *) PORT_CHECK=on;; esac
  if [ "$HEARTBEAT" = on ]; then
    uuid_ok "$NODE_ID" || die AP-110 "--node-id must be the node id from your AlphaPool dashboard (a uuid like 0f8c...-....)"
    if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then TOKEN=$(head -c 200 "$TOKEN_FILE" | tr -d '[:space:]'); fi
    token_ok "$TOKEN" || die AP-111 "the heartbeat token must be the 64-character token from your dashboard (--token, --token - or --token-file)"
  fi
  # software choices: at most one per component
  local n=0
  [ -n "$A_GW" ] && n=$((n+1)); [ -n "$A_GW_FILE" ] && n=$((n+1)); [ -n "$A_GW_URL" ] && n=$((n+1)); [ -n "$A_GW_GIT" ] && n=$((n+1))
  [ $n -le 1 ] || die AP-120 "choose one gateway option (--gateway, --gateway-file, --gateway-url or --gateway-git)"
  [ -z "$A_GW" ] || [ "$A_GW" = alphapool ] || die AP-120 "--gateway takes 'alphapool'; for another build use --gateway-file, --gateway-url or --gateway-git"
  [ -z "$A_GW_FILE" ] || [ -f "$A_GW_FILE" ] || die AP-120 "--gateway-file $A_GW_FILE does not exist"
  if [ -n "$A_GW_URL" ]; then url_ok "$A_GW_URL" && sha_ok "$A_GW_SHA" || die AP-120 "--gateway-url needs an https URL and --gateway-sha256 (64 hex, from the release you trust)"; fi
  if [ -n "$A_GW_GIT" ]; then
    [[ $A_GW_GIT =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%+=,@-]+$ ]] && [[ $A_GW_COMMIT =~ ^[0-9a-f]{40}$ ]] \
      || die AP-120 "--gateway-git needs an https repository URL and --gateway-commit (the full 40-hex commit)"
  fi
  n=0
  [ -n "$A_KN" ] && n=$((n+1)); [ -n "$A_KN_URL" ] && n=$((n+1)); [ -n "$A_KN_DIR" ] && n=$((n+1))
  [ $n -le 1 ] || die AP-121 "choose one Knots option (--knots, --knots-url or --knots-dir)"
  [ -z "$A_KN" ] || [ "$A_KN" = alphapool ] || die AP-121 "--knots takes 'alphapool'; for another build use --knots-url or --knots-dir"
  if [ -n "$A_KN_URL" ]; then url_ok "$A_KN_URL" && sha_ok "$A_KN_SHA" || die AP-121 "--knots-url needs an https URL and --knots-sha256 (64 hex, from the release's signed SHA256SUMS)"; fi
  if [ -n "$A_KN_DIR" ]; then
    { [ -x "$A_KN_DIR/bitcoind" ] && [ -x "$A_KN_DIR/bitcoin-cli" ]; } || { [ -x "$A_KN_DIR/bin/bitcoind" ] && [ -x "$A_KN_DIR/bin/bitcoin-cli" ]; } \
      || die AP-121 "--knots-dir needs bitcoind and bitcoin-cli in $A_KN_DIR or $A_KN_DIR/bin"
  fi
  return 0
}

# ==== server checks (before anything is changed) ======================================================================
OS_FLAVOR=""; MEM_MB=0
mem_mb(){ if is_dry && [ -n "${AP_DRY_MEM_MB:-}" ]; then echo "$AP_DRY_MEM_MB"; else awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo; fi; }
free_bytes(){   # free bytes on the filesystem that holds $1 (or its nearest existing parent)
  local p=$1
  if is_dry && [ -n "${AP_DRY_DISK_FREE_MB:-}" ]; then echo $(( AP_DRY_DISK_FREE_MB * 1024 * 1024 )); return; fi
  while [ ! -e "$p" ]; do p=$(dirname "$p"); done
  df --output=avail -B1 "$p" | tail -1 | tr -d ' '
}
OS_PRETTY=""
detect_os(){
  local id ver pretty osr=/etc/os-release
  is_dry && [ -n "${AP_DRY_OS_RELEASE:-}" ] && osr=$AP_DRY_OS_RELEASE
  osr_val(){ sed -n "s/^$1=//p" "$osr" 2>/dev/null | head -1 | sed 's/^"//; s/"$//'; }   # read, never sourced
  id=$(osr_val ID); ver=$(osr_val VERSION_ID); pretty=$(osr_val PRETTY_NAME); OS_PRETTY=${pretty:-unknown}
  case "$id $ver" in
    "ubuntu 24.04") OS_FLAVOR=noble;;
    "ubuntu 22.04") OS_FLAVOR=jammy;;
    *) die AP-202 "this server runs ${pretty:-an unknown system}. The installer supports Ubuntu 22.04 and 24.04 LTS (x64) only. In your provider's panel, reinstall the server with Ubuntu 24.04 (or 22.04) x64, then run the command again.";;
  esac
}
SSH_PORTS=""
detect_ssh_ports(){
  local p ports=""
  if is_dry; then ports=${AP_DRY_SSH_PORTS:-22}; else
    command -v sshd >/dev/null 2>&1 && ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
    ports="$ports $(ss -Htlnp 2>/dev/null | awk '/"sshd/{n=split($4,a,":"); print a[n]}')"
    ports="$ports $(systemctl show -p Listen ssh.socket 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | tr -dc '0-9\n')"
    [ -n "${SSH_CONNECTION:-}" ] && ports="$ports $(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
  fi
  ports="$ports $A_SSH_PORTS"
  for p in $ports; do [[ $p =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && SSH_PORTS="$SSH_PORTS $p"; done
  SSH_PORTS=$(printf '%s\n' $SSH_PORTS | sort -nu | tr '\n' ' ' | sed 's/ $//')
  [ -n "$SSH_PORTS" ] || SSH_PORTS=22
}
ours_active(){ systemctl is-active --quiet knots-node.service 2>/dev/null || systemctl is-active --quiet datum-gateway.service 2>/dev/null; }
net_fail(){ is_dry && [ "${AP_DRY_NET_FAIL:-}" = "$1" ]; }
# probe_url URL: 0 = it answers (HEAD_LEN = its Content-Length), 2 = busy (503/429: every download slot is taken),
# 3 = connection refused, 4 = not found (404), 1 = anything else (PROBE_ERR says what)
probe_url(){
  HEAD_LEN=""; PROBE_ERR=""
  if is_dry; then
    net_fail download && { PROBE_ERR="(test) no answer"; return 1; }
    case "${AP_DRY_NET_FAIL:-}:$1" in
      snapbusy:*/xbt/*) PROBE_ERR="HTTP 503"; return 2;;
      snaprefused:*/xbt/*) PROBE_ERR="connection refused"; return 3;;
      gw404:*/gw/*) PROBE_ERR="HTTP 404"; return 4;;
    esac
    return 0
  fi
  local h rc code
  h=$(curl -sS -I -L --connect-timeout 15 --max-time 30 "$1" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then PROBE_ERR=$(printf '%s' "$h" | tail -1); [ $rc -eq 7 ] && return 3; return 1; fi
  h=$(printf '%s\n' "$h" | tr -d '\r')
  code=$(printf '%s\n' "$h" | awk '/^HTTP\//{c=$2} END{print c}')
  case "$code" in
    2??) HEAD_LEN=$(printf '%s\n' "$h" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}'); return 0;;
    503|429) PROBE_ERR="HTTP $code"; return 2;;
    404) PROBE_ERR="HTTP 404"; return 4;;
    *) PROBE_ERR="HTTP ${code:-?}"; return 1;;
  esac
}
host_port(){ printf '%s' "$1" | sed -E 's#^https://([^/]+)/.*#\1#'; }
check_clock(){
  local date_hdr remote now skew
  if is_dry; then skew=${AP_DRY_CLOCK_SKEW:-0}; else
    date_hdr=$(curl -fsSI --max-time 20 "https://bitcoinknots.org/" 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)
    [ -n "$date_hdr" ] || { say "  clock: could not compare with an internet clock, skipped"; return 0; }
    remote=$(date -d "$date_hdr" +%s 2>/dev/null) || return 0
    now=$(date +%s); skew=$(( now - remote )); skew=${skew#-}
  fi
  if [ "$skew" -gt 120 ] && ! is_dry && command -v timedatectl >/dev/null; then
    say "  the clock is ${skew}s off: turning on network time"
    timedatectl set-ntp true >/dev/null 2>&1; sleep 30
    now=$(date +%s); skew=$(( now - remote - 30 )); skew=${skew#-}
  fi
  [ "$skew" -le 600 ] || die AP-207 "this server's clock is $skew seconds off. Bitcoin and secure downloads need the right time: turn on network time (timedatectl set-ntp true) and run again."
  [ "$skew" -le 120 ] || warn "this server's clock is $skew seconds off; turn on network time (timedatectl set-ntp true)"
  say "  clock: ok"
}
check_network(){
  local host
  if [ "$GW_CHOICE" = alphapool ] && ! { sha_ok "$PIN_GW_TAR" && sha_ok "$PIN_GW_BIN"; }; then
    die AP-405 "AlphaPool's gateway build for this OS is not published yet. Use Ubuntu 24.04 (recommended), or install your own gateway build with --gateway-file, --gateway-url or --gateway-git."
  fi
  for host in "$POOL_HOST" "${KNOTS_URL#https://}" "${PIN_GW_URL#https://}" "${SNAP_SRC#https://}"; do
    host=${host%%/*}; host=${host%%:*}
    if net_fail dns || { ! is_dry && ! getent hosts "$host" >/dev/null 2>&1; }; then
      die AP-301 "this server cannot look up $host (DNS). Check the server's network settings (/etc/resolv.conf) or your provider's DNS."
    fi
  done
  local st gw_host_ok=""
  if [ "$KNOTS_CHOICE" = alphapool ]; then
    probe_url "$KNOTS_URL"; st=$?
    case $st in 0|2) ;; *) die AP-302 "this server cannot download from bitcoinknots.org (${PROBE_ERR:-no answer}). Allow outgoing HTTPS (TCP 443) in your provider's firewall.";; esac
  fi
  if [ "$GW_CHOICE" = alphapool ]; then
    probe_url "$PIN_GW_URL"; st=$?
    case $st in
      0|2) gw_host_ok=$(host_port "$PIN_GW_URL");;
      4) die AP-405 "AlphaPool's gateway build for this Ubuntu release is not on the download server yet. Use Ubuntu 24.04 (recommended), or install your own gateway build with --gateway-file, --gateway-url or --gateway-git.";;
      *) die AP-302 "this server cannot download AlphaPool's gateway from ${PIN_GW_URL#https://} (${PROBE_ERR:-no answer}). Allow outgoing TCP 8444 in your provider's firewall.";;
    esac
  fi
  if [ "$SYNC_MODE" = snapshot ] && [ "$CHAIN_PRESENT" = 0 ]; then
    probe_url "$SNAP_SRC"; st=$?
    # Refused while the same server just answered for the gateway: it is shedding load, so the snapshot is busy.
    [ $st -eq 3 ] && [ -n "$gw_host_ok" ] && [ "$gw_host_ok" = "$(host_port "$SNAP_SRC")" ] && st=2
    if [ $st -eq 3 ]; then
      local i; for i in 1 2; do sleep "$(is_dry && echo 0 || echo 10)"; probe_url "$SNAP_SRC"; st=$?; [ $st -eq 3 ] || break; done
    fi
    case $st in
      0) if [ -n "$HEAD_LEN" ] && [ "$HEAD_LEN" != "$SNAP_BYTES" ]; then
           die AP-304 "the chain snapshot on the download server is not the one this installer pins (size $HEAD_LEN, expected $SNAP_BYTES). AlphaPool may be publishing a new one: get the current command from your dashboard."
         fi;;
      2) say "  the snapshot server is busy right now (all download slots are in use): the install will wait for a free slot";;
      4) die AP-304 "the chain snapshot this installer pins is not on the download server any more. AlphaPool may be publishing a new one: get the current command from your dashboard.";;
      *) die AP-302 "this server cannot download the chain snapshot from ${SNAP_SRC#https://} (${PROBE_ERR:-no answer}). Allow outgoing TCP ${SNAP_SRC_PORT} in your provider's firewall.";;
    esac
  fi
  if net_fail prime || { ! is_dry && ! timeout 12 bash -c "exec 9<>/dev/tcp/$POOL_HOST/$POOL_PORT" 2>/dev/null; }; then
    die AP-303 "this server cannot reach AlphaPool ($POOL_HOST, TCP port $POOL_PORT). Allow outgoing TCP $POOL_PORT in your provider's firewall."
  fi
  say "  network: AlphaPool and the download servers are reachable"
}
CHAIN_PRESENT=0
preflight(){
  say ""
  say "Checking this server"
  [ "$(id -u)" = 0 ] || die AP-200 "run it as root: put sudo in front of the command (sudo bash ap-node.sh ...)"
  detect_os
  [ "$(uname -m)" = x86_64 ] || die AP-203 "this server is $(uname -m); the installer's Knots and gateway builds are for x86_64 (Intel/AMD) servers"
  is_dry || [ -d /run/systemd/system ] || die AP-204 "this system does not run systemd; use a normal Ubuntu 22.04 or 24.04 VPS (not a container)"
  if [ -e /etc/alphapool/bootstrap-complete ] || [ -e /etc/alphapool/agent.env ]; then
    die AP-209 "this server was set up by AlphaPool's managed node service. Install your own node on a server in YOUR provider account."
  fi
  MEM_MB=$(mem_mb)
  [ "$MEM_MB" -ge 2800 ] || die AP-205 "this server has ${MEM_MB} MB of memory; the node needs a plan with at least 4 GB of memory and 80 GB of disk"
  [ "$MEM_MB" -ge 3400 ] || warn "this server has only ${MEM_MB} MB of memory; 4 GB or more is recommended"
  local cpus; cpus=$(nproc 2>/dev/null || echo 1)
  [ "$cpus" -ge 2 ] || warn "this server has 1 CPU; 2 or more are recommended"
  [ -e "$DD/blocks" ] || [ -e "$DD/chainstate" ] && CHAIN_PRESENT=1
  [ -e "$DD/.alphapool-restore-in-progress" ] && CHAIN_PRESENT=0
  local need avail have=0
  avail=$(free_bytes "$HOME_U")
  if [ "$CHAIN_PRESENT" = 1 ]; then need=$(( 4 * 1000**3 ))
  else case "$SYNC_MODE" in
    snapshot)   have=$(( $(stat -c %b "$DL/snapshot.tar" 2>/dev/null || echo 0) * 512 ))
                need=$(( SNAP_BYTES * 2 - have + 6 * 1000**3 ));;
    assumeutxo) need=$(( UTXO_BYTES + 30 * 1000**3 ));;
    network)    need=$(( 30 * 1000**3 ));;
  esac; fi
  [ "$avail" -ge "$need" ] || die AP-206 "this server has $(gb "$avail") GB of free disk; the node needs $(gb "$need") GB now (the snapshot is downloaded, checked, then unpacked). Pick a plan with 80 GB or more."
  say "  server: $OS_PRETTY, $cpus CPU, ${MEM_MB} MB memory, $(gb "$avail") GB free"
  local p
  if ! ours_active && command -v ss >/dev/null 2>&1; then
    for p in "$STRATUM_PORT" $ALIAS_PORTS 8333 8332 7152; do
      if ss -Htln "sport = :$p" 2>/dev/null | grep -q .; then
        die AP-208 "port $p is already used by another program on this server. This installer sets up its own node and gateway; use a fresh server (or another --stratum-port)."
      fi
    done
  fi
  detect_ssh_ports
  check_clock
  check_network
}

# ==== plan + confirmation ==============================================================================================
software_plan(){
  KNOTS_CHOICE=alphapool; GW_CHOICE=alphapool
  [ -n "$A_KN_URL" ] && KNOTS_CHOICE=url
  [ -n "$A_KN_DIR" ] && KNOTS_CHOICE=dir
  [ -n "$A_GW_FILE" ] && GW_CHOICE="file"
  [ -n "$A_GW_URL" ] && GW_CHOICE=url
  [ -n "$A_GW_GIT" ] && GW_CHOICE=git
  # a re-run keeps what is installed unless a software option was given
  if [ -z "$A_KN$A_KN_URL$A_KN_DIR" ] && [ -r "$STATE" ]; then
    local s; s=$(kv_get "$STATE" knots_source) && [ "$s" != alphapool ] && KNOTS_CHOICE=keep
  fi
  if [ -z "$A_GW$A_GW_FILE$A_GW_URL$A_GW_GIT" ] && [ -r "$STATE" ]; then
    local s; s=$(kv_get "$STATE" gateway_source) && [ "$s" != alphapool ] && GW_CHOICE=keep
  fi
  case "$OS_FLAVOR" in
    jammy) PIN_GW_URL=$GW_JAMMY_URL; PIN_GW_TAR=$GW_JAMMY_TAR_SHA256; PIN_GW_BIN=$GW_JAMMY_SHA256;;
    *)     PIN_GW_URL=$GW_URL; PIN_GW_TAR=$GW_TAR_SHA256; PIN_GW_BIN=$GW_SHA256;;
  esac
  SNAP_SRC=${SNAP_FROM:-$SNAP_URL}
  SNAP_SRC_PORT=$(printf '%s' "$SNAP_SRC" | sed -nE 's#^https://[^/:]+:([0-9]+)/.*#\1#p'); SNAP_SRC_PORT=${SNAP_SRC_PORT:-443}
}
show_plan(){
  say ""
  say "This installs an AlphaPool node on this server:"
  say "  payout address : $ADDRESS"
  say "  block name     : ${TAG:-(none)}"
  say "  rigs connect to: port $STRATUM_PORT${ALIAS_PORTS:+ (also $ALIAS_PORTS)}"
  case "$KNOTS_CHOICE" in alphapool) say "  node software  : Bitcoin Knots $KNOTS_VER (AlphaPool's tested pin)";;
    keep) say "  node software  : keep the bitcoind already installed (your choice)";; *) say "  node software  : your Bitcoin Knots build ($KNOTS_CHOICE)";; esac
  case "$GW_CHOICE" in alphapool) say "  gateway        : AlphaPool's DATUM gateway release 3.1 (tested pin)";;
    keep) say "  gateway        : keep the gateway already installed (your choice)";; *) say "  gateway        : your DATUM gateway build ($GW_CHOICE)";; esac
  case "$SYNC_MODE" in snapshot) [ "$CHAIN_PRESENT" = 1 ] && say "  chain data     : keep the chain data already on this server" \
                                   || say "  chain data     : AlphaPool's chain snapshot ($(gb "$SNAP_BYTES") GB download, sha256-pinned)";;
    assumeutxo) say "  chain data     : assumeutxo from $UTXO_URL (height $UTXO_HEIGHT)";;
    network) say "  chain data     : full sync from the Bitcoin network (days on a small server)";; esac
  if [ "$FIREWALL" = on ]; then say "  firewall (ufw) : allow SSH port(s) $SSH_PORTS, stratum $STRATUM_PORT${ALIAS_PORTS:+ $ALIAS_PORTS}, Bitcoin peers 8333; deny other incoming"
  else say "  firewall       : left as it is (--firewall off)"; fi
  if [ "$HEARTBEAT" = on ]; then say "  heartbeat      : ON for node $NODE_ID (status only; off: alphapool-node heartbeat off)"
  else say "  heartbeat      : off"; fi
  say "  AlphaPool access to this server: none (no keys, no remote commands, no update channel)"
}
confirm(){
  [ "$YES" = 1 ] && return 0
  if ! [ -r /dev/tty ] || ! { : < /dev/tty; } 2>/dev/null; then die AP-100 "no terminal to ask in: add --yes to run without questions"; fi
  local ans=""
  { IFS= read -r -p "Type yes to install, anything else to stop: " ans < /dev/tty; } 2>/dev/tty || true
  [ "$ans" = yes ] || { say "Stopped. Nothing was changed."; drain; exit 1; }
}
save_settings(){
  install -d -m 0755 "$ETC"
  [ -e "$CONF" ] || { printf '# AlphaPool node settings (written by the installer; change them by running it again)\n' > "$CONF"; chmod 0644 "$CONF"; }
  kv_set "$CONF" ADDRESS "$ADDRESS"; kv_set "$CONF" TAG "$TAG"
  kv_set "$CONF" STRATUM_PORT "$STRATUM_PORT"; kv_set "$CONF" ALIAS_PORTS "$ALIAS_PORTS"
  kv_set "$CONF" PUBLIC_HOST "$PUBLIC_HOST"; kv_set "$CONF" SYNC_MODE "$SYNC_MODE"; kv_set "$CONF" SNAPSHOT_URL "$SNAP_FROM"
  kv_set "$CONF" FIREWALL "$FIREWALL"; kv_set "$CONF" PORT_CHECK "$PORT_CHECK"
  kv_set "$CONF" HEARTBEAT "$HEARTBEAT"; kv_set "$CONF" NODE_ID "$NODE_ID"; kv_set "$CONF" SSH_PORTS "$SSH_PORTS"
  if [ "$SYNC_MODE" = assumeutxo ]; then
    kv_set "$CONF" UTXO_URL "$UTXO_URL"; kv_set "$CONF" UTXO_SHA256 "$UTXO_SHA256"
    kv_set "$CONF" UTXO_BYTES "$UTXO_BYTES"; kv_set "$CONF" UTXO_HEIGHT "$UTXO_HEIGHT"
  fi
  if [ "$HEARTBEAT" = on ]; then (umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE.new" && mv -f "$TOKEN_FILE.new" "$TOKEN_FILE"); chmod 0600 "$TOKEN_FILE"
  else rm -f "$TOKEN_FILE"; fi
  # one-shot software request for the worker
  : > "$REQ"; chmod 0600 "$REQ"
  [ "$A_KN" = alphapool ] && kv_set "$REQ" knots "alphapool"
  [ -n "$A_KN_URL" ] && kv_set "$REQ" knots "url $A_KN_URL $A_KN_SHA"
  [ -n "$A_KN_DIR" ] && kv_set "$REQ" knots "dir $(cd "$A_KN_DIR" && pwd)"
  [ "$A_GW" = alphapool ] && kv_set "$REQ" gateway "alphapool"
  [ -n "$A_GW_FILE" ] && kv_set "$REQ" gateway "file $(cd "$(dirname "$A_GW_FILE")" && pwd)/$(basename "$A_GW_FILE")"
  [ -n "$A_GW_URL" ] && kv_set "$REQ" gateway "url $A_GW_URL $A_GW_SHA"
  [ -n "$A_GW_GIT" ] && kv_set "$REQ" gateway "git $A_GW_GIT $A_GW_COMMIT"
  chmod 0600 "$REQ"
}

# ==== downloads ========================================================================================================
# fetch URL DEST: small files with curl. In test mode the fixture with the same file name is copied instead.
fetch(){
  local url=$1 dest=$2 name=${1##*/} i
  if is_dry; then
    [ -n "${AP_DRY_FIXTURES:-}" ] && [ -f "$AP_DRY_FIXTURES/$name" ] && { cp "$AP_DRY_FIXTURES/$name" "$dest"; return $?; }
    say "  DRY: no fixture for $name"; return 1
  fi
  for i in 1 2 3 4 5; do
    curl -fsSL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" && mv -f "$dest.part" "$dest" && return 0
    say "  download of $name failed (attempt $i of 5), retrying in 15 s"; sleep 15
  done
  return 1
}
# Downloads from a server that admits a few downloads at a time (AlphaPool's snapshot server: 4 at full speed). When
# every slot is taken it answers 503, or refuses connections: the installer then WAITS for a slot, with a growing pause
# (30 s doubling to 5 min, plus jitter so waiting servers do not retry in step). Waiting never counts as a failure.
# Real failures (no progress, not a busy answer) are retried AP_DL_MAX_ERRORS times in a row.
num_or(){ [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '%s' "$2"; }
SLOT_WAIT_BASE=$(num_or "${AP_SLOT_WAIT_BASE:-}" 30)
SLOT_WAIT_MAX=$(num_or "${AP_SLOT_WAIT_MAX:-}" 300)
SLOT_WAIT_LIMIT=$(num_or "${AP_SLOT_WAIT_LIMIT:-}" 86400)      # a whole day of waiting, then the miner is told to re-run
DL_MAX_ERRORS=$(num_or "${AP_DL_MAX_ERRORS:-}" 15)
DL_RETRY_SLEEP=$(num_or "${AP_DL_RETRY_SLEEP:-}" 30)
ARIA_TRIES=$(num_or "${AP_ARIA_MAX_TRIES:-}" 5)
on_disk(){ echo $(( $(stat -c %b "$1" 2>/dev/null || echo 0) * 512 )); }
# slot_state URL: 0 = a download slot is free, 2 = busy (503/429, or the connection is refused), 1 = something else
slot_state(){
  local code rc
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 -r 0-0 "$1" 2>/dev/null); rc=$?
  case "$code" in 200|206) return 0;; 503|429) return 2;; esac
  [ $rc -eq 7 ] && return 2
  return 1
}
SLOT_WAITED=0; SLOT_NAP=0
slot_wait(){   # DEST TOTAL LABEL: one pause while every download slot is taken. Fails only after SLOT_WAIT_LIMIT.
  local nap mins
  [ "$SLOT_WAITED" -lt "$SLOT_WAIT_LIMIT" ] || return 1
  [ "$SLOT_NAP" -gt 0 ] || SLOT_NAP=$SLOT_WAIT_BASE
  nap=$(( SLOT_NAP + RANDOM % (SLOT_NAP / 4 + 1) ))
  mins=$(( SLOT_WAITED / 60 ))
  status_set "step $STEP_N/$TOTAL_STEPS: waiting for a download slot ($mins min)"
  rstate downloading "$(on_disk "$1")" "$2"
  say "  the download server is busy (all download slots are in use): waiting for a download slot ($mins min)"
  console_note "waiting for a download slot for the $3 ($mins min)"
  sleep "$nap"
  SLOT_WAITED=$(( SLOT_WAITED + nap ))
  SLOT_NAP=$(( SLOT_NAP * 2 )); [ "$SLOT_NAP" -le "$SLOT_WAIT_MAX" ] || SLOT_NAP=$SLOT_WAIT_MAX
  return 0
}
# fetch_big URL DEST BYTES LABEL: resumable (aria2, 4 connections; a re-run resumes the partial file).
# Returns 0 done, 1 failed (errors without progress), 3 still no download slot after SLOT_WAIT_LIMIT.
fetch_big(){
  local url=$1 dest=$2 total=$3 label=$4 dir name errors=0 rc st before
  dir=$(dirname "$dest"); name=$(basename "$dest")
  if is_dry && [ "${AP_DRY_REAL_DOWNLOAD:-0}" != 1 ]; then
    local fx=${AP_DRY_FIXTURES:-}/${url##*/}
    [ -n "${AP_DRY_FIXTURES:-}" ] && [ -f "$fx" ] && { cp "$fx" "$dest"; return $?; }
    say "  DRY: no fixture for ${url##*/}"; return 1
  fi
  if [ -f "$dest" ] && [ ! -f "$dest.aria2" ] && [ "$(stat -c %s "$dest")" = "$total" ]; then say "  $label already downloaded"; return 0; fi
  [ -f "$dest" ] && [ ! -f "$dest.aria2" ] && rm -f "$dest"       # a stray partial without aria2's control file
  SLOT_WAITED=0; SLOT_NAP=0
  while :; do
    slot_state "$url"; st=$?
    if [ $st -eq 2 ]; then slot_wait "$dest" "$total" "$label" || return 3; continue; fi
    SLOT_NAP=0
    before=$(on_disk "$dest")
    progress_loop "$dest" "$total" "$label" & BG_PID=$!
    aria2c -q -c -x4 -s4 -k8M --file-allocation=none --max-tries="$ARIA_TRIES" --retry-wait=10 --connect-timeout=20 --timeout=60 \
      --auto-file-renaming=false --allow-overwrite=true --console-log-level=error -d "$dir" -o "$name" "$url"; rc=$?
    kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""
    [ $rc -eq 0 ] && break
    # aria2 exit 29 = the server answered 503 (busy) to every try: wait for a slot, never a failure
    if [ $rc -eq 29 ]; then slot_wait "$dest" "$total" "$label" || return 3; continue; fi
    slot_state "$url"; st=$?
    if [ $st -eq 2 ]; then slot_wait "$dest" "$total" "$label" || return 3; continue; fi
    if [ "$(on_disk "$dest")" -gt "$before" ]; then errors=0; else errors=$(( errors + 1 )); fi
    [ "$errors" -lt "$DL_MAX_ERRORS" ] || return 1
    say "  the $label download was interrupted (aria2 error $rc); it resumes in $DL_RETRY_SLEEP s"; sleep "$DL_RETRY_SLEEP"
  done
  [ "$(stat -c %s "$dest" 2>/dev/null)" = "$total" ] || return 1
}
progress_loop(){   # FILE TOTAL LABEL: % done from the blocks actually written (aria2 writes 4 parts at once)
  local f=$1 total=$2 label=$3 got prev=0 t0 now rate eta pct last_print=0 last_console=0
  t0=$(date +%s)
  while sleep 10; do
    got=$(( $(stat -c %b "$f" 2>/dev/null || echo 0) * 512 )); [ "$got" -le "$total" ] || got=$total
    now=$(date +%s); pct=$(( got * 100 / total ))
    rstate downloading "$got" "$total"
    status_set "step $STEP_N/$TOTAL_STEPS: downloading the $label: $pct%"
    if [ $(( now - last_print )) -ge 30 ]; then
      rate=$(( (got - prev) / (now - last_print > 0 ? now - last_print : 1) ))
      [ "$last_print" -eq 0 ] && rate=$(( got / (now - t0 + 1) ))
      eta=""; [ "$rate" -gt 0 ] && eta=", about $(( (total - got) / rate / 60 + 1 )) min left"
      say "  $label: $pct% ($(gb "$got") of $(gb "$total") GB, $(( rate / 1000000 )) MB/s$eta)"
      prev=$got; last_print=$now
    fi
    if [ $(( now - last_console )) -ge 120 ]; then console_note "downloading the $label: $pct%"; last_console=$now; fi
  done
}
rstate(){   # restore progress for the status command and the optional heartbeat
  install -d -m 0755 "$RUN" 2>/dev/null
  printf '{"state":"%s","bytes":%s,"total":%s,"ts":%s}\n' "$1" "${2:-0}" "${3:-0}" "$(date -u +%s)" > "$RUN/restore.json.tmp" 2>/dev/null \
    && mv -f "$RUN/restore.json.tmp" "$RUN/restore.json" 2>/dev/null
  return 0
}

# ==== step 1: packages =================================================================================================
PKGS="curl jq aria2 ufw ca-certificates iptables libcurl4-openssl-dev libjansson-dev libmicrohttpd-dev libsodium-dev"
BUILD_PKGS="build-essential cmake pkg-config git"
apt_install(){
  if is_dry; then printf 'DRY: apt-get install %s\n' "$*" >> "$PLAN"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1   # 22.04's needrestart is interactive by default
  local try alog=/var/log/alphapool-node-apt.log
  for try in 1 2 3; do
    # first boot: cloud-init or the automatic updates may hold the package lock for a while; wait instead of failing.
    # apt's own output goes to its own log; its tail is shown only if it fails.
    if { apt-get -o DPkg::Lock::Timeout=1200 update -qq \
           && apt-get -o DPkg::Lock::Timeout=1200 -o Dpkg::Options::=--force-confold install -y -qq --no-install-recommends "$@"; } \
         > "$alog.last" 2>&1; then
      cat "$alog.last" >> "$alog"; rm -f "$alog.last"; return 0
    fi
    cat "$alog.last" >> "$alog"; tail -n 8 "$alog.last" | sed 's/^/  apt: /'
    say "  package install attempt $try failed, retrying in 20 s (full output: $alog)"; sleep 20
  done
  return 1
}
step_packages(){
  step 1 "System packages"
  say "  installing: $PKGS"
  # shellcheck disable=SC2086
  apt_install $PKGS || die AP-501 "the system packages could not be installed (apt). Check that the server can reach its package mirror, then run again."
}

# ==== step 2: user, folders, swap, heartbeat ===========================================================================
step_base(){
  step 2 "User, folders, swap and services"
  id -u "$U" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$U" || die AP-502 "could not create the user $U"
  install -d -o "$U" -g "$U" -m 0750 "$HOME_U" "$DD" "$GWD"
  install -d -m 0755 "$ETC" "$LIB" "$RUN" "$DL"
  [ -e "$STATE" ] || : > "$STATE"
  kv_set "$STATE" installer_version "$AP_VERSION"
  install -m 0755 "$SELF_COPY" "$LIB/install.sh.new" 2>/dev/null && mv -f "$LIB/install.sh.new" "$LIB/install.sh"
  write_cli
  write_needrestart
  setup_swap
  setup_heartbeat
}
setup_swap(){
  local swap_mb; swap_mb=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)
  is_dry && swap_mb=${AP_DRY_SWAP_MB:-0}
  if [ "$MEM_MB" -ge 6144 ]; then say "  swap: not needed (${MEM_MB} MB memory)"; return 0; fi
  if [ "${swap_mb:-0}" -ge 1024 ] && ! systemctl is-enabled --quiet alphapool-swap.service 2>/dev/null; then
    say "  swap: ${swap_mb} MB already configured"; return 0
  fi
  cat > "$LIB/swap-on" <<'EOS'
#!/bin/bash
# AlphaPool node swap: compressed swap in RAM (zram, half the memory), or a 2 GB swap file where the kernel has no zram.
set -u
s=$(awk '/^MemTotal:/{print int($2/2048)}' /proc/meminfo)M
if modprobe zram 2>/dev/null; then
  dev=$(zramctl --find --size "$s" --algorithm zstd 2>/dev/null || zramctl --find --size "$s" 2>/dev/null)
  if [ -n "$dev" ] && mkswap "$dev" >/dev/null 2>&1 && swapon -p 100 "$dev"; then echo "$dev" > /run/alphapool-swap; exit 0; fi
  [ -n "${dev:-}" ] && zramctl --reset "$dev" 2>/dev/null
fi
f=/var/lib/alphapool-swapfile
if [ ! -f "$f" ]; then
  { fallocate -l 2G "$f" 2>/dev/null || dd if=/dev/zero of="$f" bs=1M count=2048 status=none; } && chmod 600 "$f" && mkswap "$f" >/dev/null || exit 1
fi
swapon "$f" && echo "$f" > /run/alphapool-swap
EOS
  cat > "$LIB/swap-off" <<'EOS'
#!/bin/bash
d=$(cat /run/alphapool-swap 2>/dev/null) || exit 0
swapoff "$d" 2>/dev/null
case "$d" in /dev/zram*) zramctl --reset "$d" 2>/dev/null;; esac
rm -f /run/alphapool-swap
EOS
  chmod 0755 "$LIB/swap-on" "$LIB/swap-off"
  write_managed "$UNITS/alphapool-swap.service" 0644 <<'UNIT'
[Unit]
Description=AlphaPool node swap (zram, or a swap file)
DefaultDependencies=no
After=local-fs.target
Before=swap.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/alphapool/swap-on
ExecStop=/usr/local/lib/alphapool/swap-off
[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  run_q systemctl enable --now alphapool-swap.service || warn "swap could not be turned on; the node runs without it"
  say "  swap: compressed swap in memory (zram) or a 2 GB swap file"
}
write_needrestart(){
  # needrestart (Ubuntu runs it after every apt run, automatic updates included) must never restart the node or the
  # gateway by itself: an update would bounce your rigs. Restart them when it suits you: alphapool-node restart
  install -d -m 0755 /etc/needrestart /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/alphapool.conf <<'NR'
$nrconf{restart} = 'l';
$nrconf{override_rc}{qr(^datum-gateway\.service$)} = 0;
$nrconf{override_rc}{qr(^knots-node\.service$)} = 0;
NR
  chmod 0644 /etc/needrestart/conf.d/alphapool.conf
}
write_resume_unit(){
  # An install interrupted by a reboot continues by itself at the next boot (cloud-init only runs once).
  write_managed "$UNITS/alphapool-install-resume.service" 0644 <<'UNIT'
[Unit]
Description=Continue an interrupted AlphaPool node install
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/alphapool/install-in-progress
[Service]
Type=simple
ExecStart=/bin/bash /usr/local/lib/alphapool/install.sh --worker --resumed
[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  run_q systemctl enable alphapool-install-resume.service
}

# ==== optional heartbeat ===============================================================================================
setup_heartbeat(){
  if [ "$HEARTBEAT" != on ]; then
    if [ -e "$UNITS/alphapool-heartbeat.timer" ]; then
      run systemctl disable --now alphapool-heartbeat.timer
      rm -f "$UNITS/alphapool-heartbeat.timer" "$UNITS/alphapool-heartbeat.service" "$HB_CONF" "$TOKEN_FILE" "$LIB/heartbeat-agent"
      run systemctl daemon-reload
      say "  heartbeat: turned off"
    else say "  heartbeat: off (nothing is sent to AlphaPool)"; fi
    return 0
  fi
  [ -s "$TOKEN_FILE" ] || die AP-111 "the heartbeat token is missing; give it with --token - or --token-file"
  printf 'NODE_ID=%s\nENDPOINT=%s\nSTRATUM_PORT=%s\nPUBLIC_HOST=%s\n' "$NODE_ID" "$HEARTBEAT_URL" "$STRATUM_PORT" "$PUBLIC_HOST" > "$HB_CONF"
  chmod 0644 "$HB_CONF"
  write_agent
  write_managed "$UNITS/alphapool-heartbeat.service" 0644 <<'UNIT'
[Unit]
Description=AlphaPool node status heartbeat (optional; turn off: alphapool-node heartbeat off)
[Service]
Type=oneshot
User=alphapool
Group=alphapool
LoadCredential=token:/etc/alphapool/heartbeat.token
ExecStart=/usr/local/lib/alphapool/heartbeat-agent
TimeoutStartSec=60
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
UNIT
  write_managed "$UNITS/alphapool-heartbeat.timer" 0644 <<'UNIT'
[Unit]
Description=AlphaPool node status heartbeat every 20 s (turn off: alphapool-node heartbeat off)
[Timer]
OnBootSec=60
OnUnitActiveSec=20
AccuracySec=5
[Install]
WantedBy=timers.target
UNIT
  run systemctl daemon-reload
  run_q systemctl enable --now alphapool-heartbeat.timer || warn "the heartbeat timer could not be started"
  say "  heartbeat: on for node $NODE_ID (status only; turn off: alphapool-node heartbeat off)"
}
write_agent(){
  cat > "$LIB/heartbeat-agent.new" <<'AGENT'
#!/bin/bash
# alphapool heartbeat agent (v5): the OPTIONAL status report from a self-hosted AlphaPool node to its owner's
# dashboard. Runs as the unprivileged node user every 20 s; the token arrives through systemd's LoadCredential.
# SENDS: node sync progress and peers, chain-snapshot restore progress, whether the node and the gateway run, how many
#        rigs are connected, whether the live job pays AlphaPool, the stratum host:port, the sha256 of the gateway
#        executable that runs.
# NEVER SENDS: RPC credentials, the gateway admin password, keys, config files, wallet data, rig passwords.
# The reply is discarded: nothing AlphaPool sends back is ever read or run. Failures are silent and never touch mining.
set -uo pipefail
CONF=${AP_HB_CONF:-/etc/alphapool/heartbeat.conf}
[ -r "$CONF" ] || exit 0
val(){ sed -n "s/^$1=//p" "$CONF" | tail -1; }
NODE_ID=$(val NODE_ID); ENDPOINT=$(val ENDPOINT); STRATUM_PORT=$(val STRATUM_PORT); PUBLIC_HOST=$(val PUBLIC_HOST)
TOKEN=$(head -c 200 "${CREDENTIALS_DIRECTORY:-/nonexistent}/token" 2>/dev/null || head -c 200 "${AP_HB_TOKEN_FILE:-/nonexistent}" 2>/dev/null)
TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')
[[ $NODE_ID =~ ^[0-9a-f-]{36}$ ]] && [[ $TOKEN =~ ^[0-9a-f]{64}$ ]] && [[ $ENDPOINT =~ ^https://[A-Za-z0-9./:_-]+$ ]] || exit 0
[[ ${STRATUM_PORT:-} =~ ^[0-9]{1,5}$ ]] || STRATUM_PORT=23334
CLI=${AP_HB_CLI:-/usr/local/bin/bitcoin-cli -datadir=/home/alphapool/.bitcoin}
GW_API=${AP_HB_GW_API:-http://127.0.0.1:7152}
RESTORE_STATE=${AP_HB_RESTORE:-/run/alphapool/restore.json}
OWN=$(sed -n 's/^ADDRESS=//p' "${AP_HB_NODE_CONF:-/etc/alphapool/node.conf}" 2>/dev/null | tail -1)

int(){ [[ ${1:-} =~ ^[0-9]{1,15}$ ]] && printf '%s' "$1" || printf 0; }
frac(){ [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]] && printf '%s' "$1" || printf 0; }
unit(){ local s; s=$(systemctl is-active "$1" 2>/dev/null | head -n 1)
        case "$s" in active|activating|deactivating|inactive|failed) printf '%s' "$s";; *) printf unknown;; esac; }

# shellcheck disable=SC2086   # CLI is a command line on purpose
chain=$(timeout 5 $CLI getblockchaininfo 2>/dev/null) || chain=''
[ -n "$chain" ] || chain='{}'
IFS=$'\t' read -r h hd pg ibd sz < <(jq -r '[(.blocks // 0), (.headers // 0), (.verificationprogress // 0),
    (if has("initialblockdownload") then .initialblockdownload else true end), (.size_on_disk // 0)] | @tsv' \
    <<<"$chain" 2>/dev/null) || true
h=$(int "${h:-}"); hd=$(int "${hd:-}"); pg=$(frac "${pg:-}"); sz=$(int "${sz:-}")
[ "${ibd:-}" = false ] || ibd=true
# shellcheck disable=SC2086
peers=$(int "$(timeout 5 $CLI getconnectioncount 2>/dev/null)")
ns=$(unit knots-node); gs=$(unit datum-gateway)
rigs=$(int "$(ss -Htn state established "( sport = :${STRATUM_PORT} )" 2>/dev/null | wc -l | tr -d ' ')")
# payouts in the live job to addresses OTHER than the miner's own: before AlphaPool's payout list arrives, the
# gateway's page shows one row paying the whole block to the miner's own address, which is not an AlphaPool job yet
payees=$(int "$(timeout 3 curl -sS "${GW_API}/coinbaser" 2>/dev/null | head -c 200000 \
          | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${OWN:-none}")")
gpid=$(systemctl show -p MainPID --value datum-gateway 2>/dev/null)
[[ ${gpid:-} =~ ^[1-9][0-9]*$ ]] || gpid=$(pidof -s datum_gateway 2>/dev/null)
exe=''
[[ ${gpid:-} =~ ^[1-9][0-9]*$ ]] && exe=$(timeout 5 sha256sum "/proc/$gpid/exe" 2>/dev/null | cut -d' ' -f1)
[[ ${exe:-} =~ ^[0-9a-f]{64}$ ]] || exe=''
rs=$(head -c 1000 "$RESTORE_STATE" 2>/dev/null) || rs=''
[ -n "$rs" ] || rs='{}'
IFS=$'\t' read -r rst rb rt < <(jq -r '[(.state // "none"), (.bytes // 0), (.total // 0)] | @tsv' <<<"$rs" 2>/dev/null) || true
case "${rst:-}" in none|skipped|downloading|verifying|extracting|done|failed) ;; *) rst=none;; esac
rb=$(int "${rb:-}"); rt=$(int "${rt:-}")
pub=${PUBLIC_HOST:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}
[[ ${pub:-} =~ ^[A-Za-z0-9.-]{1,253}$ ]] || pub=''
if   [ "$ns" != active ] && [[ $rst =~ ^(downloading|verifying|extracting)$ ]]; then ph=restoring
elif [ "$ns" != active ];                                  then ph=starting
elif [ "$ibd" = true ];                                    then ph=syncing
elif awk "BEGIN{exit !($pg < 0.9999)}";                    then ph=syncing
elif [ "$gs" != active ];                                  then ph=gateway-starting
elif [ "$payees" -gt 0 ] && [ "$rigs" -gt 0 ];             then ph=mining
elif [ "$payees" -gt 0 ];                                  then ph=ready
else                                                            ph=connecting
fi
body=$(printf '{"node_id":"%s","ts":%s,"phase":"%s","node":{"state":"%s","height":%s,"headers":%s,"progress":%s,"ibd":%s,"peers":%s,"size_on_disk":%s},"endpoint":{"host":"%s","port":%s},"gateway":{"state":"%s","coinbase_payees":%s,"rigs":%s,"exe_sha256":"%s"},"restore":{"state":"%s","bytes":%s,"total":%s},"agent":{"v":5}}' \
  "$NODE_ID" "$(date -u +%s)" "$ph" "$ns" "$h" "$hd" "$pg" "$ibd" "$peers" "$sz" "$pub" "$(int "$STRATUM_PORT")" \
  "$gs" "$payees" "$rigs" "$exe" "$rst" "$rb" "$rt")
timeout 8 curl -sS -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" --data-binary "$body" >/dev/null 2>&1
exit 0
AGENT
  chmod 0755 "$LIB/heartbeat-agent.new" && mv -f "$LIB/heartbeat-agent.new" "$LIB/heartbeat-agent"
}

# ==== alphapool-node: the everyday command ============================================================================
write_cli(){
  cat > "$CLI_BIN.new" <<'CLI'
#!/bin/bash
# alphapool-node: everyday commands for this AlphaPool node (installed by the AlphaPool node installer).
# Where things live: binaries /usr/local/bin/bitcoind, /usr/local/bin/bitcoin-cli,
#   /home/alphapool/datum_gateway/datum_gateway; configs /home/alphapool/.bitcoin/bitcoin.conf,
#   /home/alphapool/datum_gateway/datum_gateway_config.json; services knots-node, datum-gateway,
#   alphapool-gateway-start (/etc/systemd/system); settings /etc/alphapool/node.conf; log /var/log/alphapool-node.log.
# Edit any of them by hand: re-running the installer keeps your edits and your software choices.
set -uo pipefail
export LC_ALL=C
INSTALLER=/usr/local/lib/alphapool/install.sh
ETC=/etc/alphapool
DD=/home/alphapool/.bitcoin
GWD=/home/alphapool/datum_gateway
LOG=/var/log/alphapool-node.log
usage(){ cat <<'U'
alphapool-node status                       node, gateway, rigs, payout address, heartbeat, warnings
alphapool-node logs [node|gateway|install]  recent log lines
alphapool-node start|stop|restart [node|gateway|all]   (stop: until the next reboot)
alphapool-node disable | enable             keep the node and gateway off across reboots / turn them back on
alphapool-node heartbeat off | on <node id> | status   the optional status report to your AlphaPool dashboard
alphapool-node switch gateway alphapool                      AlphaPool's tested gateway (release 3.1)
alphapool-node switch gateway file /path/to/datum_gateway    a gateway binary you built or downloaded
alphapool-node switch gateway url URL SHA256                 a gateway release (archive or binary) + its sha256
alphapool-node switch gateway git REPO_URL COMMIT            build a DATUM gateway from source
alphapool-node switch knots alphapool                        AlphaPool's tested Bitcoin Knots 29.4.2
alphapool-node switch knots url URL SHA256                   another Knots release archive (.tar.gz) + its sha256
alphapool-node switch knots dir /path                        bitcoind + bitcoin-cli you built
alphapool-node set address <payout address>  |  set tag "<block name>"
alphapool-node gateway-page                 how to open the gateway's own web page (through SSH)
alphapool-node repair                       run this node's installer again with its saved settings
alphapool-node uninstall [--keep-chain]     remove everything the installer added
U
}
need_root(){ [ "$(id -u)" = 0 ] || { echo "run it as root: sudo alphapool-node $*"; exit 1; }; }
cli(){ timeout 15 /usr/local/bin/bitcoin-cli -datadir="$DD" "$@"; }
val(){ sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1; }
status(){
  local port addr tag info b h ibd peers ns gs rigs payees host w res
  port=$(val STRATUM_PORT $ETC/node.conf); port=${port:-23334}
  addr=$(val ADDRESS $ETC/node.conf); tag=$(val TAG $ETC/node.conf)
  echo "AlphaPool node (installer $(val installer_version $ETC/state))"
  res=$(cat $ETC/last-result 2>/dev/null)
  if [ -e $ETC/install-in-progress ]; then echo "  install  : running - $(cat /run/alphapool/install-status 2>/dev/null)"
  else case "$res" in ok*) echo "  install  : complete";; failed*) echo "  install  : FAILED (${res#failed }) - see: alphapool-node logs install";; esac; fi
  ns=$(systemctl is-active knots-node 2>/dev/null); gs=$(systemctl is-active datum-gateway 2>/dev/null)
  info=$(cli getblockchaininfo 2>/dev/null)
  if [ -n "$info" ]; then
    b=$(jq -r .blocks <<<"$info"); h=$(jq -r .headers <<<"$info"); ibd=$(jq -r .initialblockdownload <<<"$info")
    peers=$(cli getconnectioncount 2>/dev/null || echo "?")
    if [ "$ibd" = false ] && [ "$b" = "$h" ]; then echo "  node     : $ns, at the tip (block $b), $peers peers"
    elif [ "$b" = "$h" ]; then echo "  node     : $ns, getting block headers from peers (block $b), $peers peers"
    else echo "  node     : $ns, catching up: block $b of $h ($((h - b)) to go), $peers peers"; fi
  else echo "  node     : $ns (not answering yet: starting or loading the chain)"; fi
  rigs=$(ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l)
  payees=$(timeout 3 curl -sS http://127.0.0.1:7152/coinbaser 2>/dev/null | head -c 200000 \
           | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${addr:-none}")
  if [ "$gs" = active ]; then
    if [ "$payees" -gt 0 ]; then echo "  gateway  : active, connected to AlphaPool (live job with $payees payouts)"
    else echo "  gateway  : active, no AlphaPool job yet (alphapool-node logs gateway)"; fi
  else echo "  gateway  : $gs - $(sed 's/ [0-9T:-]*Z$//' /run/alphapool/gateway-gate 2>/dev/null || echo 'starts once the node has caught up')"; fi
  host=$(val PUBLIC_HOST $ETC/node.conf)
  [ -n "$host" ] || host=$(val DETECTED_HOST $ETC/node.conf)        # what the installer found (also behind NAT)
  [ -n "$host" ] || host=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  echo "  rigs     : $rigs connected - point rigs at stratum+tcp://$host:$port (worker: anything)"
  echo "  payouts  : $addr${tag:+   block name: $tag}"
  echo "  software : $(/usr/local/bin/bitcoind -version 2>/dev/null | head -1) [$(val knots_source $ETC/state)]"
  echo "             DATUM gateway sha256 $(sha256sum $GWD/datum_gateway 2>/dev/null | cut -c1-16)... [$(val gateway_source $ETC/state)]"
  if systemctl is-enabled --quiet alphapool-heartbeat.timer 2>/dev/null; then echo "  heartbeat: on (status only) - turn off: alphapool-node heartbeat off"
  else echo "  heartbeat: off (nothing is reported to AlphaPool)"; fi
  w=$(sed -n 's/^[[:space:]]*blockmaxweight[[:space:]]*=[[:space:]]*//p' $DD/bitcoin.conf 2>/dev/null | head -1)
  if ! [[ ${w:-x} =~ ^[0-9]+$ ]] || [ "$w" -gt 740000 ]; then
    echo "  WARNING  : blockmaxweight=${w:-default} in $DD/bitcoin.conf; AlphaPool's payout requirement is 740000 or lower"
    echo "             (AlphaPool pays miners in the block's coinbase; above it the payout list may not fit)"
  fi
}
svc(){
  case "$2" in
    node) systemctl "$1" knots-node.service;;
    gateway) if [ "$1" = start ]; then systemctl start alphapool-gateway-start.service; else systemctl "$1" datum-gateway.service; fi;;
    all) case "$1" in
           stop) systemctl stop alphapool-gateway-start.service datum-gateway.service knots-node.service;;
           start) systemctl start knots-node.service alphapool-gateway-start.service;;
           restart) systemctl restart knots-node.service
                    systemctl is-active --quiet datum-gateway.service && systemctl restart datum-gateway.service
                    systemctl start alphapool-gateway-start.service;;
         esac;;
    *) usage; exit 1;;
  esac
}
case "${1:-status}" in
  status) need_root status; status;;
  logs) need_root logs
        case "${2:-all}" in
          node) journalctl -u knots-node -n 60 --no-pager;;
          gateway) journalctl -u datum-gateway -n 60 --no-pager;;
          install) tail -n 80 "$LOG";;
          *) tail -n 25 "$LOG"; journalctl -u knots-node -u datum-gateway -n 40 --no-pager;;
        esac;;
  start|stop|restart) need_root "$1"; svc "$1" "${2:-all}";;
  disable) need_root disable
           systemctl disable --now alphapool-gateway-start.service datum-gateway.service knots-node.service alphapool-heartbeat.timer 2>/dev/null
           echo "the node and the gateway are stopped and stay off after a reboot (alphapool-node enable turns them on)";;
  enable) need_root enable; systemctl enable --now knots-node.service alphapool-gateway-start.service
          [ "$(val HEARTBEAT $ETC/node.conf)" = on ] && systemctl enable --now alphapool-heartbeat.timer; true;;
  heartbeat) need_root heartbeat
     case "${2:-status}" in
       off) systemctl disable --now alphapool-heartbeat.timer 2>/dev/null; rm -f $ETC/heartbeat.token
            sed -i 's/^HEARTBEAT=.*/HEARTBEAT=off/' $ETC/node.conf
            echo "heartbeat off: nothing is reported to AlphaPool any more";;
       on) [ -n "${3:-}" ] || { echo "usage: alphapool-node heartbeat on <node id from your dashboard>"; exit 1; }
           exec bash "$INSTALLER" --repair --node-id "$3" --token -;;
       *) if systemctl is-enabled --quiet alphapool-heartbeat.timer 2>/dev/null; then
            echo "heartbeat: on for node $(val NODE_ID $ETC/node.conf) (status only); turn off: alphapool-node heartbeat off"
          else echo "heartbeat: off"; fi;;
     esac;;
  switch) need_root switch
     case "${2:-} ${3:-}" in
       "gateway alphapool") exec bash "$INSTALLER" --repair --gateway alphapool;;
       "gateway file") exec bash "$INSTALLER" --repair --gateway-file "${4:?path to the binary}";;
       "gateway url") exec bash "$INSTALLER" --repair --gateway-url "${4:?url}" --gateway-sha256 "${5:?sha256}";;
       "gateway git") exec bash "$INSTALLER" --repair --gateway-git "${4:?repository url}" --gateway-commit "${5:?commit}";;
       "knots alphapool") exec bash "$INSTALLER" --repair --knots alphapool;;
       "knots url") exec bash "$INSTALLER" --repair --knots-url "${4:?url}" --knots-sha256 "${5:?sha256}";;
       "knots dir") exec bash "$INSTALLER" --repair --knots-dir "${4:?directory}";;
       *) usage; exit 1;;
     esac;;
  set) need_root set
     case "${2:-}" in
       address) exec bash "$INSTALLER" --repair --address "${3:?payout address}";;
       tag) exec bash "$INSTALLER" --repair --tag "${3-}";;
       *) usage; exit 1;;
     esac;;
  gateway-page) need_root gateway-page
     echo "The gateway's own page listens on 127.0.0.1:7152 (this server only). From your computer:"
     echo "  ssh -L 7152:127.0.0.1:7152 <you>@<this server>     then open http://127.0.0.1:7152"
     echo "Its admin pages ask for user 'admin' and this password: $(jq -r .api.admin_password $GWD/datum_gateway_config.json 2>/dev/null)";;
  repair) need_root repair; exec bash "$INSTALLER" --repair "${@:2}";;
  uninstall) need_root uninstall; exec bash "$INSTALLER" --uninstall "${@:2}";;
  help|-h|--help) usage;;
  *) usage; exit 1;;
esac
CLI
  chmod 0755 "$CLI_BIN.new" && mv -f "$CLI_BIN.new" "$CLI_BIN"
}

# ==== files the installer writes but you may edit: a re-run keeps your edits ===========================================
# write_managed FILE MODE < content: writes FILE when it does not exist or still has exactly the content the installer
# wrote last time (its sha256 is in the state file). If you changed it, it stays as it is and the installer's version
# goes next to it as FILE.alphapool-new.
WM_RESULT=""
write_managed(){
  local f=$1 mode=$2 key new_sha cur_sha rec_sha tmp
  key="file:$f"
  tmp=$(mktemp "$f.XXXXXX.tmp") || return 1                     # mktemp creates it 0600
  cat > "$tmp"; chmod "$mode" "$tmp"
  new_sha=$(sha_of "$tmp")
  if [ -e "$f" ]; then
    cur_sha=$(sha_of "$f"); rec_sha=$(kv_get "$STATE" "$key" || true)
    if [ "$cur_sha" = "$new_sha" ]; then rm -f "$tmp"; kv_set "$STATE" "$key" "$new_sha"; WM_RESULT=same; return 0; fi
    if [ "$cur_sha" != "$rec_sha" ]; then
      mv -f "$tmp" "$f.alphapool-new"
      say "  kept your edited $f (the installer's version is in $f.alphapool-new)"
      WM_RESULT=kept; return 0
    fi
  fi
  mv -f "$tmp" "$f"; kv_set "$STATE" "$key" "$new_sha"
  rm -f "$f.alphapool-new"
  WM_RESULT=written
}

# ==== step 3: Bitcoin Knots ============================================================================================
NODE_CHANGED=0; GW_CHANGED=0
knots_untouched(){   # the installed bitcoind is exactly what the installer put there
  local rec; rec=$(kv_get "$STATE" knots_installed_sha256) || return 1
  [ -n "$rec" ] && [ "$(sha_of /usr/local/bin/bitcoind)" = "$rec" ]
}
install_knots_archive(){   # TARBALL: ONLY <top>/bin/bitcoind and <top>/bin/bitcoin-cli come out, and only as regular files
  local t=$1 bd bc kx l
  # (release archives carry library symlinks elsewhere; nothing but these two members is ever unpacked)
  l=$(mktemp) || die AP-403 "no temp file"
  tar -tvzf "$t" > "$l" 2>/dev/null || { rm -f "$l"; die AP-403 "the Knots archive cannot be read"; }
  bd=$(awk 'substr($1,1,1) == "-" && $NF ~ /^[^\/.][^\/]*\/bin\/bitcoind$/ {print $NF; exit}' "$l")
  bc=$(awk 'substr($1,1,1) == "-" && $NF ~ /^[^\/.][^\/]*\/bin\/bitcoin-cli$/ {print $NF; exit}' "$l")
  rm -f "$l"
  [ -n "$bd" ] && [ -n "$bc" ] || die AP-403 "the Knots archive has no regular files <dir>/bin/bitcoind and <dir>/bin/bitcoin-cli"
  kx=$(mktemp -d "$DL/knots.XXXXXX")
  tar -xzf "$t" -C "$kx" --no-same-owner "$bd" "$bc" || die AP-403 "the Knots archive could not be unpacked"
  { [ -f "$kx/$bd" ] && [ ! -L "$kx/$bd" ] && [ -f "$kx/$bc" ] && [ ! -L "$kx/$bc" ]; } \
    || { rm -rf "$kx"; die AP-402 "the Knots archive's bitcoind/bitcoin-cli are not plain files: refused"; }
  install -m 0755 "$kx/$bd" /usr/local/bin/bitcoind.new && mv -f /usr/local/bin/bitcoind.new /usr/local/bin/bitcoind
  install -m 0755 "$kx/$bc" /usr/local/bin/bitcoin-cli.new && mv -f /usr/local/bin/bitcoin-cli.new /usr/local/bin/bitcoin-cli
  rm -rf "$kx"
}
step_knots(){
  step 3 "Bitcoin Knots"
  local req s
  req=$(kv_get "$REQ" knots || true)
  if [ -z "$req" ]; then
    s=$(kv_get "$STATE" knots_source || true)
    if [ -x /usr/local/bin/bitcoind ] && { [ "${s:-}" != alphapool ] || ! knots_untouched; }; then
      say "  keeping the bitcoind installed on this server (sha256 $(sha_of /usr/local/bin/bitcoind | cut -c1-16)...): your choice"
      say "  (the installer never replaces software you chose; back to AlphaPool's pin: alphapool-node switch knots alphapool)"
      [ "${s:-}" = alphapool ] && kv_set "$STATE" knots_source by-hand
      kv_set "$STATE" knots_installed_sha256 "$(sha_of /usr/local/bin/bitcoind)"
      knots_compat_note
      return 0
    fi
    req=alphapool
  fi
  local kt=$DL/knots.tar.gz
  case "$req" in
    alphapool)
      if [ "$(kv_get "$STATE" knots_source || true)" = alphapool ] && [ "$(kv_get "$STATE" knots_pin || true)" = "$KNOTS_SHA256" ] \
         && knots_untouched && [ -x /usr/local/bin/bitcoin-cli ]; then
        say "  Bitcoin Knots $KNOTS_VER is installed (AlphaPool pin)"; return 0
      fi
      say "  downloading Bitcoin Knots $KNOTS_VER"
      fetch "$KNOTS_URL" "$kt" || die AP-305 "the Knots download failed (${KNOTS_URL})"
      [ "$(sha_of "$kt")" = "$KNOTS_SHA256" ] || { rm -f "$kt"; die AP-401 "the Knots download does not match its pinned sha256: refused (nothing was installed)"; }
      install_knots_archive "$kt"
      rm -f "$kt"
      /usr/local/bin/bitcoind -version 2>/dev/null | head -1 | grep -qF "$KNOTS_VER" || die AP-404 "the installed bitcoind is not $KNOTS_VER"
      kv_set "$STATE" knots_source alphapool; kv_set "$STATE" knots_pin "$KNOTS_SHA256"
      say "  installed Bitcoin Knots $KNOTS_VER (sha256 of the release checked)";;
    url\ *)
      local url sha; url=$(printf '%s' "$req" | cut -d' ' -f2); sha=$(printf '%s' "$req" | cut -d' ' -f3)
      say "  downloading your Knots build: $url"
      fetch "$url" "$kt" || die AP-305 "the download of $url failed"
      [ "$(sha_of "$kt")" = "$sha" ] || { rm -f "$kt"; die AP-401 "$url does not match the sha256 you gave: refused (nothing was installed)"; }
      install_knots_archive "$kt"; rm -f "$kt"
      kv_set "$STATE" knots_source url; kv_set "$STATE" knots_origin "$url"; kv_set "$STATE" knots_pin "$sha";;
    dir\ *)
      local kd=${req#dir }
      [ -x "$kd/bitcoind" ] || kd=$kd/bin
      install -m 0755 "$kd/bitcoind" /usr/local/bin/bitcoind.new && mv -f /usr/local/bin/bitcoind.new /usr/local/bin/bitcoind
      install -m 0755 "$kd/bitcoin-cli" /usr/local/bin/bitcoin-cli.new && mv -f /usr/local/bin/bitcoin-cli.new /usr/local/bin/bitcoin-cli
      kv_set "$STATE" knots_source dir; kv_set "$STATE" knots_origin "$kd"; kv_set "$STATE" knots_pin "";;
  esac
  kv_set "$STATE" knots_installed_sha256 "$(sha_of /usr/local/bin/bitcoind)"
  kv_del_req knots
  NODE_CHANGED=1
  [ "$req" = alphapool ] || knots_compat_note
}
knots_compat_note(){
  local v; v=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1)
  say "  bitcoind reports: ${v:-(no version line)}"
  case "$v" in *"$KNOTS_VER"*) ;; *)
    warn "this bitcoind is not the Knots $KNOTS_VER that AlphaPool tests. It must follow the same chain and rules as AlphaPool (Knots 29.4.2 or later in that line); otherwise your gateway may build jobs AlphaPool cannot use. Back to the tested build: alphapool-node switch knots alphapool";;
  esac
}
kv_del_req(){ [ -e "$REQ" ] && { grep -v -- "^$1=" "$REQ" > "$REQ.tmp"; mv -f "$REQ.tmp" "$REQ"; chmod 0600 "$REQ"; }; return 0; }

# ==== step 4: DATUM gateway ============================================================================================
gw_untouched(){ local rec; rec=$(kv_get "$STATE" gateway_installed_sha256) || return 1; [ -n "$rec" ] && [ "$(sha_of "$GW_BIN")" = "$rec" ]; }
install_gw_binary(){   # FILE: put it in place (as the node user's file) and smoke-test it
  install -o "$U" -g "$U" -m 0755 "$1" "$GW_BIN.new" && mv -f "$GW_BIN.new" "$GW_BIN" || die AP-503 "could not install the gateway binary"
}
unpack_gw_archive(){   # ARCHIVE -> GX (temp dir, unpacked by the unprivileged node user)
  tar_safe "$1" || die AP-402 "the gateway archive has unsafe members (links, absolute paths or ..): refused"
  GX=$(mktemp -d "$DL/gw.XXXXXX"); chown "$U:$U" "$GX"
  runuser -u "$U" -- tar -xf "$1" -C "$GX" --no-same-owner --no-same-permissions || die AP-403 "the gateway archive could not be unpacked"
}
gw_smoke(){
  local missing
  missing=$(ldd "$GW_BIN" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
  if [ -n "$missing" ]; then
    if is_dry; then say "  DRY: gateway libraries absent in the test image ($missing): smoke test skipped"; return 0; fi
    die AP-504 "the gateway binary is missing libraries on this server: $missing"
  fi
  if runuser -u "$U" -- "$GW_BIN" --example-conf >/dev/null 2>&1 || runuser -u "$U" -- "$GW_BIN" --version >/dev/null 2>&1; then return 0; fi
  return 1
}
step_gateway(){
  step 4 "DATUM gateway"
  local req s gt=$DL/gateway.download
  req=$(kv_get "$REQ" gateway || true)
  if [ -z "$req" ]; then
    s=$(kv_get "$STATE" gateway_source || true)
    if [ -x "$GW_BIN" ] && { [ "${s:-}" != alphapool ] || ! gw_untouched; }; then
      say "  keeping the gateway installed on this server (sha256 $(sha_of "$GW_BIN" | cut -c1-16)...): your choice"
      say "  (the installer never replaces software you chose; back to AlphaPool's build: alphapool-node switch gateway alphapool)"
      [ "${s:-}" = alphapool ] && kv_set "$STATE" gateway_source by-hand
      kv_set "$STATE" gateway_installed_sha256 "$(sha_of "$GW_BIN")"
      gw_compat_note
      return 0
    fi
    req=alphapool
  fi
  case "$req" in
    alphapool)
      if [ "$(kv_get "$STATE" gateway_source || true)" = alphapool ] && [ "$(sha_of "$GW_BIN")" = "$PIN_GW_BIN" ] && gw_untouched; then
        say "  AlphaPool gateway release 3.1 is installed"; return 0
      fi
      sha_ok "$PIN_GW_TAR" && sha_ok "$PIN_GW_BIN" || die AP-405 "AlphaPool's gateway build for this Ubuntu release is not published yet; use Ubuntu 24.04, or install your own build with --gateway-file/--gateway-url/--gateway-git"
      say "  downloading AlphaPool's DATUM gateway release 3.1"
      fetch "$PIN_GW_URL" "$gt" || die AP-305 "the gateway download failed (${PIN_GW_URL})"
      [ "$(sha_of "$gt")" = "$PIN_GW_TAR" ] || { rm -f "$gt"; die AP-401 "the gateway download does not match its pinned sha256: refused before unpacking (nothing was installed)"; }
      unpack_gw_archive "$gt"
      local gb_; gb_=$(find "$GX" -maxdepth 2 -name datum_gateway -type f | head -1)
      [ -n "$gb_" ] || die AP-403 "no datum_gateway binary in the gateway archive"
      [ "$(sha_of "$gb_")" = "$PIN_GW_BIN" ] || { rm -rf "$GX" "$gt"; die AP-401 "the gateway binary does not match its pinned sha256: refused (nothing was installed)"; }
      install_gw_binary "$gb_"
      local bi; bi=$(find "$GX" -maxdepth 2 -name BUILDINFO -type f | head -1)
      [ -n "$bi" ] && install -m 0644 "$bi" "$ETC/gateway.buildinfo"
      rm -rf "$GX" "$gt"
      kv_set "$STATE" gateway_source alphapool; kv_set "$STATE" gateway_origin "$PIN_GW_URL"
      gw_smoke || die AP-504 "AlphaPool's gateway binary does not run on this server";;
    file\ *)
      local f=${req#file }
      [ -f "$f" ] || die AP-120 "the gateway file $f is gone"
      install_gw_binary "$f"
      kv_set "$STATE" gateway_source file; kv_set "$STATE" gateway_origin "$f";;
    url\ *)
      local url sha; url=$(printf '%s' "$req" | cut -d' ' -f2); sha=$(printf '%s' "$req" | cut -d' ' -f3)
      say "  downloading your gateway build: $url"
      fetch "$url" "$gt" || die AP-305 "the download of $url failed"
      [ "$(sha_of "$gt")" = "$sha" ] || { rm -f "$gt"; die AP-401 "$url does not match the sha256 you gave: refused (nothing was installed)"; }
      if tar -tf "$gt" >/dev/null 2>&1; then
        unpack_gw_archive "$gt"
        local cand; cand=$(find "$GX" -maxdepth 3 -type f \( -name datum_gateway -o -name ratum-gateway -o -name 'datum*gateway*' \) -perm -u+x | head -1)
        [ -n "$cand" ] || die AP-403 "no gateway executable (datum_gateway / ratum-gateway) in $url"
        install_gw_binary "$cand"; rm -rf "$GX"
      else install_gw_binary "$gt"; fi
      rm -f "$gt"
      kv_set "$STATE" gateway_source url; kv_set "$STATE" gateway_origin "$url";;
    git\ *)
      local repo commit src; repo=$(printf '%s' "$req" | cut -d' ' -f2); commit=$(printf '%s' "$req" | cut -d' ' -f3)
      say "  building a DATUM gateway from $repo at $commit (a few minutes)"
      # shellcheck disable=SC2086
      apt_install $BUILD_PKGS || die AP-501 "the build tools could not be installed"
      src=$HOME_U/src/gw-${commit:0:12}
      install -d -o "$U" -g "$U" "$HOME_U/src"
      if is_dry; then say "  DRY: build skipped"; else
        rm -rf "$src"
        runuser -u "$U" -- git clone -q "$repo" "$src" || die AP-506 "git clone of $repo failed"
        runuser -u "$U" -- git -C "$src" checkout -q --detach "$commit" || die AP-506 "commit $commit is not in $repo"
        [ "$(runuser -u "$U" -- git -C "$src" rev-parse HEAD)" = "$commit" ] || die AP-506 "the checkout is not commit $commit"
        runuser -u "$U" -- bash -c "cd '$src' && cmake -S . -B . >/dev/null && make -j\$(nproc) >/dev/null" || die AP-506 "the gateway did not build (see $src)"
        [ -x "$src/datum_gateway" ] || die AP-506 "the build produced no datum_gateway"
        install_gw_binary "$src/datum_gateway"
      fi
      kv_set "$STATE" gateway_source git; kv_set "$STATE" gateway_origin "$repo@$commit";;
  esac
  kv_set "$STATE" gateway_installed_sha256 "$(sha_of "$GW_BIN")"
  kv_del_req gateway
  GW_CHANGED=1
  if [ "$req" != alphapool ]; then gw_smoke || warn "the gateway binary did not answer --example-conf or --version; it may not run on this server"; gw_compat_note; fi
  say "  gateway binary sha256 $(sha_of "$GW_BIN")"
}
gw_compat_note(){
  [ "$(sha_of "$GW_BIN")" = "$PIN_GW_BIN" ] && return 0
  warn "you run a DATUM gateway build AlphaPool has not tested (sha256 $(sha_of "$GW_BIN" | cut -c1-16)...). AlphaPool tests its own release 3.1; other builds may handle AlphaPool's payout list differently. If mining does not work as expected: alphapool-node switch gateway alphapool"
}

# ==== step 5: chain data ===============================================================================================
step_chain(){
  step 5 "Chain data"
  if [ -e "$DD/.alphapool-restore-in-progress" ]; then
    say "  an earlier unpack was interrupted: removing the partial chain data and unpacking again"
    rm -rf "$DD/blocks" "$DD/chainstate"
  elif [ -e "$DD/blocks" ] || [ -e "$DD/chainstate" ]; then
    say "  chain data is already on this server: kept (never wiped)"; rstate skipped; return 0
  fi
  case "$SYNC_MODE" in
    network)    say "  no snapshot: the node syncs from the Bitcoin network (this takes days on a small server)"; rstate skipped; return 0;;
    assumeutxo) say "  assumeutxo: the UTXO file is loaded after the node has the block headers (step 9)"; rstate skipped; return 0;;
  esac
  local f=$DL/snapshot.tar avail need got
  got=$(( $(stat -c %b "$f" 2>/dev/null || echo 0) * 512 ))
  avail=$(free_bytes "$DL"); need=$(( SNAP_BYTES - got + SNAP_BYTES + 2 * 1000**3 ))
  [ "$avail" -ge "$need" ] || die AP-206 "only $(gb "$avail") GB free; the snapshot needs $(gb "$need") GB more (download + unpack)"
  say_t "  downloading the chain snapshot ($(gb "$SNAP_BYTES") GB) from ${SNAP_SRC#https://}"
  rstate downloading "$got" "$SNAP_BYTES"
  fetch_big "$SNAP_SRC" "$f" "$SNAP_BYTES" "chain snapshot"; local frc=$?
  [ $frc -eq 3 ] && die AP-307 "the snapshot server had no free download slot for $(( SLOT_WAITED / 3600 )) hours. Run the same command again later: the download resumes where it stopped."
  [ $frc -eq 0 ] || die AP-306 "the chain snapshot download did not finish (network trouble). Run the same command again: the download resumes where it stopped."
  say_t "  downloaded; checking the snapshot's sha256 (1-3 minutes)"
  rstate verifying "$SNAP_BYTES" "$SNAP_BYTES"; status_set "step 5/$TOTAL_STEPS: checking the chain snapshot"
  if [ "$(sha_of "$f")" != "$SNAP_SHA256" ]; then
    rm -f "$f" "$f.aria2"; rstate failed 0 "$SNAP_BYTES"
    die AP-401 "the downloaded chain snapshot does not match its pinned sha256 (corrupted download): it was deleted. Run the same command again to download it again."
  fi
  # Only blocks/ and chainstate/ may come out of the archive: no wallets, no config, no traversal, no links.
  if ! tar_only_chain "$f" || ! tar_safe "$f"; then
    rm -f "$f"; rstate failed 0 "$SNAP_BYTES"
    die AP-402 "the chain snapshot has members outside blocks/ and chainstate/ (or links): refused"
  fi
  say_t "  sha256 matches the pin; unpacking the chain snapshot"
  rstate extracting "$SNAP_BYTES" "$SNAP_BYTES"
  touch "$DD/.alphapool-restore-in-progress"; chown "$U:$U" "$DD/.alphapool-restore-in-progress"
  # unpacked by the node user, so ownership is right by construction (no foreign uids, no root files)
  runuser -u "$U" -- tar -xf "$f" -C "$DD" --no-same-owner --no-same-permissions blocks chainstate & BG_PID=$!
  local n=0
  while kill -0 "$BG_PID" 2>/dev/null; do
    sleep 2; n=$(( n + 1 )); [ $(( n % 10 )) -eq 0 ] || continue
    got=$(du -sb "$DD/blocks" "$DD/chainstate" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    say "  unpacking: $(( got * 100 / SNAP_BYTES ))%"; status_set "step 5/$TOTAL_STEPS: unpacking the chain snapshot: $(( got * 100 / SNAP_BYTES ))%"
  done
  wait "$BG_PID" || { BG_PID=""; rm -rf "$DD/blocks" "$DD/chainstate"; rstate failed 0 "$SNAP_BYTES"; die AP-405 "unpacking the chain snapshot failed (disk full?); the partial data was removed. Run the same command again."; }
  BG_PID=""
  rm -f "$DD/.alphapool-restore-in-progress" "$f" "$f.aria2"
  rstate "done" "$SNAP_BYTES" "$SNAP_BYTES"
  say_t "  chain snapshot in place ($(du -sh "$DD/blocks" | cut -f1) blocks, $(du -sh "$DD/chainstate" | cut -f1) chainstate)"
}

# ==== step 6: configuration ============================================================================================
dbcache_mb(){ local m=$(( MEM_MB / 4 / 50 * 50 )); [ "$m" -ge 450 ] || m=450; [ "$m" -le 4096 ] || m=4096; echo "$m"; }
render_bitcoin_conf(){
  cat <<CONF
# AlphaPool node: Bitcoin Knots settings, written by the AlphaPool node installer.
# You may edit this file: once you change it, re-running the installer leaves it alone (it writes its own version
# next to it as bitcoin.conf.alphapool-new). Restart the node after an edit: alphapool-node restart node
server=1
daemon=0
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=datum
rpcpassword=$1
prune=4000
dbcache=$(dbcache_mb)
maxmempool=300
maxconnections=32
maxuploadtarget=5000
# AlphaPool's payout requirement: AlphaPool pays every miner directly in the coinbase transaction of each block, and
# that payout list needs room in the block. This chain's blocks hold at most 800,000 weight units and Knots fills a
# template up to blockmaxweight minus 8,000; 740000 leaves about 17 KB for the payout list. With a higher value a busy
# mempool can leave too little room, and your gateway cannot build an AlphaPool job. Keep it at or below 740000.
blockmaxweight=$PAYOUT_MAX_BLOCKWEIGHT
blocknotify=curl -fsS -m 5 -o /dev/null http://127.0.0.1:7152/NOTIFY
CONF
}
conf_val(){ sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | head -1 | tr -d '\r'; }   # first value wins, like bitcoind
check_blockmaxweight(){
  local v; v=$(conf_val "$BTC_CONF" blockmaxweight)
  if [ -z "$v" ] || ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -gt "$PAYOUT_MAX_BLOCKWEIGHT" ]; then
    local shown=${v:-unset}
    warn "bitcoin.conf has blockmaxweight=$shown. AlphaPool's payout requirement is blockmaxweight=$PAYOUT_MAX_BLOCKWEIGHT or lower: AlphaPool pays miners in the block's coinbase, and above it a busy mempool can leave too little room for that payout list, so your gateway cannot build AlphaPool jobs. Your setting is kept; set it in $BTC_CONF and run: alphapool-node restart node"
  fi
}
write_bitcoin_conf(){
  local rp; rp=$(conf_val "$BTC_CONF" rpcpassword); [[ $rp =~ ^[0-9a-f]{48}$ ]] || rp=$(rand_hex 24)
  write_managed "$BTC_CONF" 0600 < <(render_bitcoin_conf "$rp")
  [ "$WM_RESULT" = written ] && NODE_CHANGED=1
  chown "$U:$U" "$BTC_CONF" "$BTC_CONF.alphapool-new" 2>/dev/null
  chmod 0600 "$BTC_CONF.alphapool-new" 2>/dev/null
  check_blockmaxweight
}
write_gateway_conf(){
  local base='{}' ru rp ap tmp ok
  if [ -s "$GW_CONF" ]; then
    if jq -e 'type == "object"' "$GW_CONF" >/dev/null 2>&1; then base=$(cat "$GW_CONF")
    else cp -p "$GW_CONF" "$GW_CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"; warn "the gateway config was not valid JSON: saved a copy and wrote a fresh one"; fi
  fi
  ru=$(conf_val "$BTC_CONF" rpcuser); rp=$(conf_val "$BTC_CONF" rpcpassword)
  ap=$(printf '%s' "$base" | jq -r '.api.admin_password // ""'); [ -n "$ap" ] || ap=$(rand_hex 24)
  tmp=$(mktemp "$GW_CONF.XXXXXX")
  # AlphaPool's keys are set; every other key you added or changed is kept (defaults only fill what is missing).
  printf '%s' "$base" | jq --arg addr "$ADDRESS" --arg tag "$TAG" --arg ph "$POOL_HOST" --argjson pp "$POOL_PORT" \
      --arg pk "$POOL_PUBKEY" --argjson sp "$STRATUM_PORT" --arg ru "$ru" --arg rp "$rp" --arg ap "$ap" \
      --arg ik "$GWD/identity.key" --arg cookie "$DD/.cookie" '
    def dflt(p; v): if getpath(p) == null then setpath(p; v) else . end;
    (if ($ru != "" and $rp != "") then .bitcoind.rpcuser = $ru | .bitcoind.rpcpassword = $rp | del(.bitcoind.rpccookiefile)
     else del(.bitcoind.rpcuser, .bitcoind.rpcpassword) | .bitcoind.rpccookiefile = $cookie end)
    | .bitcoind.rpcurl = "http://127.0.0.1:8332"
    | dflt(["bitcoind","work_update_seconds"]; 10) | dflt(["bitcoind","notify_fallback"]; true)
    | dflt(["stratum","listen_addr"]; "0.0.0.0") | .stratum.listen_port = $sp
    | dflt(["stratum","vardiff_min"]; 16384) | dflt(["stratum","vardiff_target_shares_min"]; 8)
    | dflt(["api","listen_addr"]; "127.0.0.1") | .api.listen_port = 7152 | .api.admin_password = $ap
    | dflt(["api","modify_conf"]; false)
    | .mining.pool_address = $addr | .mining.coinbase_tag_primary = "DATUM-AP" | .mining.coinbase_tag_secondary = $tag
    | dflt(["mining","allow_hasher_time_rolling"]; false)
    | .datum.pool_host = $ph | .datum.pool_port = $pp | .datum.pool_pubkey = $pk
    | dflt(["datum","identity_key_path"]; $ik) | dflt(["datum","pool_pass_workers"]; true)
    | dflt(["datum","pool_pass_full_users"]; false) | dflt(["datum","pooled_mining_only"]; true)
  ' > "$tmp" 2>/dev/null; ok=$?
  [ $ok -eq 0 ] && jq -e --arg a "$ADDRESS" --arg t "$TAG" --arg h "$POOL_HOST" --argjson p "$POOL_PORT" --argjson s "$STRATUM_PORT" \
     '.datum.pool_host == $h and .datum.pool_port == $p and .mining.pool_address == $a and .mining.coinbase_tag_secondary == $t
      and .stratum.listen_port == $s and .api.listen_port == 7152' "$tmp" >/dev/null 2>&1 \
    || { rm -f "$tmp"; die AP-505 "the gateway configuration could not be written (jq)"; }
  chown "$U:$U" "$tmp"; chmod 0600 "$tmp"
  if [ -e "$GW_CONF" ] && cmp -s "$tmp" "$GW_CONF"; then rm -f "$tmp"; else mv -f "$tmp" "$GW_CONF"; GW_CHANGED=1; fi
  [ "$(jq -r '.api.listen_addr' "$GW_CONF")" = 127.0.0.1 ] || warn "the gateway's admin API listens on $(jq -r '.api.listen_addr' "$GW_CONF") (your setting); the firewall does not open port 7152"
}
write_units(){
  write_managed "$UNITS/knots-node.service" 0644 <<UNIT
[Unit]
Description=Bitcoin Knots node (AlphaPool node)
After=network-online.target
Wants=network-online.target
[Service]
User=$U
Group=$U
ExecStart=/usr/local/bin/bitcoind -conf=$BTC_CONF -datadir=$DD
Restart=always
RestartSec=10
TimeoutStopSec=600
[Install]
WantedBy=multi-user.target
UNIT
  # No [Install]: alphapool-gateway-start starts the gateway once the node has caught up (no job from a stale node,
  # no idle connection to AlphaPool while the node syncs). After that it is an ordinary service.
  write_managed "$UNITS/datum-gateway.service" 0644 <<UNIT
[Unit]
Description=DATUM gateway (AlphaPool node)
After=knots-node.service
Wants=knots-node.service
[Service]
User=$U
Group=$U
WorkingDirectory=$GWD
ExecStart=$GW_BIN -c $GW_CONF
Restart=always
RestartSec=15
LimitNOFILE=65536
UNIT
  write_managed "$UNITS/alphapool-gateway-start.service" 0644 <<'UNIT'
[Unit]
Description=Start the DATUM gateway once the node has caught up (AlphaPool node)
After=knots-node.service
Wants=knots-node.service
[Service]
Type=simple
ExecStart=/usr/local/lib/alphapool/start-gateway-when-synced
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
UNIT
  cat > "$LIB/start-gateway-when-synced.new" <<'GATE'
#!/bin/bash
# Starts datum-gateway once the local node is at the chain tip, then exits: no job from a stale node, and no idle
# connection to AlphaPool while the node syncs.
set -u
CLI=${AP_GATE_CLI:-/usr/local/bin/bitcoin-cli}; R=${AP_GATE_RUN:-/run/alphapool}
cli(){ timeout 20 "$CLI" -datadir=/home/alphapool/.bitcoin "$@"; }
mkdir -p "$R"                      # /run is emptied at every boot
while :; do
  info=$(cli getblockchaininfo 2>/dev/null)
  if [ -n "$info" ] && printf '%s' "$info" | jq -e '.initialblockdownload == false and .blocks == .headers and .headers > 0' >/dev/null 2>&1; then
    printf 'synced %s\n' "$(date -u +%FT%TZ)" > "$R/gateway-gate" 2>/dev/null
    exec systemctl start datum-gateway.service
  fi
  printf 'waiting for the node to catch up %s\n' "$(date -u +%FT%TZ)" > "$R/gateway-gate"
  sleep "${AP_GATE_SLEEP:-30}"
done
GATE
  chmod 0755 "$LIB/start-gateway-when-synced.new" && mv -f "$LIB/start-gateway-when-synced.new" "$LIB/start-gateway-when-synced"
  write_aliases
  run systemctl daemon-reload
}
write_aliases(){
  if [ -z "$ALIAS_PORTS" ]; then
    if [ -e "$UNITS/datum-port-aliases.service" ]; then
      run systemctl disable --now datum-port-aliases.service
      [ -x "$LIB/port-aliases" ] && run "$LIB/port-aliases" delete
      rm -f "$UNITS/datum-port-aliases.service" "$LIB/port-aliases"
    fi
    return 0
  fi
  cat > "$LIB/port-aliases" <<EOS
#!/bin/bash
# Stratum on ${ALIAS_PORTS} as aliases of ${STRATUM_PORT} (nat REDIRECT). "delete" removes the rules. Idempotent.
for p in ${ALIAS_PORTS}; do
  for t in iptables ip6tables; do
    if [ "\${1:-}" = delete ]; then \$t -t nat -D PREROUTING -p tcp --dport "\$p" -j REDIRECT --to-ports ${STRATUM_PORT} 2>/dev/null
    else \$t -t nat -C PREROUTING -p tcp --dport "\$p" -j REDIRECT --to-ports ${STRATUM_PORT} 2>/dev/null \\
      || \$t -t nat -A PREROUTING -p tcp --dport "\$p" -j REDIRECT --to-ports ${STRATUM_PORT} 2>/dev/null; fi
  done
done
exit 0
EOS
  chmod 0755 "$LIB/port-aliases"
  write_managed "$UNITS/datum-port-aliases.service" 0644 <<UNIT
[Unit]
Description=DATUM stratum port aliases (${ALIAS_PORTS} -> ${STRATUM_PORT})
After=network-online.target ufw.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB/port-aliases
ExecStop=$LIB/port-aliases delete
[Install]
WantedBy=multi-user.target
UNIT
}
step_config(){
  step 6 "Configuration"
  write_bitcoin_conf
  write_gateway_conf
  write_units
  {
    echo "installer=$AP_VERSION"
    echo "knots=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1)"
    echo "knots_sha256=$(sha_of /usr/local/bin/bitcoind)"
    echo "knots_source=$(kv_get "$STATE" knots_source || true)"
    echo "gateway_sha256=$(sha_of "$GW_BIN")"
    echo "gateway_source=$(kv_get "$STATE" gateway_source || true)"
    echo "snapshot_sha256=$SNAP_SHA256"
  } > "$ETC/versions"
  say "  node: prune 4000 MB, dbcache $(dbcache_mb) MB, blockmaxweight $(conf_val "$BTC_CONF" blockmaxweight); RPC on 127.0.0.1 only"
  say "  gateway: pays $ADDRESS, stratum :$STRATUM_PORT, admin page on 127.0.0.1:7152 only, pool $POOL_HOST:$POOL_PORT"
}

# ==== step 7: firewall =================================================================================================
ufw_active(){ if is_dry; then [ "${AP_DRY_UFW_ACTIVE:-0}" = 1 ]; else ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; fi; }
step_firewall(){
  step 7 "Firewall"
  if [ "$FIREWALL" != on ]; then say "  left as it is (--firewall off). Open TCP $STRATUM_PORT for your rigs yourself."; return 0; fi
  local p was
  was=$(kv_get "$STATE" ufw_was_active || true)
  if [ -z "$was" ]; then
    if ufw_active; then was=1; else was=0; fi
    kv_set "$STATE" ufw_was_active "$was"
  elif [ "$(kv_get "$STATE" ufw_enabled_by_installer || true)" = 1 ] && ! ufw_active; then
    say "  ufw is off: you turned it off after the install, so it stays off (--firewall on in a new install turns it on)"
    return 0
  fi
  # Allow rules only: rules you already have are never removed, and your SSH port(s) are allowed before anything else.
  for p in $SSH_PORTS; do run_q ufw allow "$p/tcp" comment "AlphaPool node: SSH (your login, kept open)" || die AP-509 "ufw could not allow SSH port $p (to manage the firewall yourself: run again with --firewall off)"; done
  run_q ufw allow "$STRATUM_PORT/tcp" comment "AlphaPool node: stratum (rigs)" || die AP-509 "ufw could not allow port $STRATUM_PORT (to manage the firewall yourself: run again with --firewall off)"
  for p in $ALIAS_PORTS; do run_q ufw allow "$p/tcp" comment "AlphaPool node: stratum alias" || die AP-509 "ufw could not allow port $p (to manage the firewall yourself: run again with --firewall off)"; done
  run_q ufw allow 8333/tcp comment "AlphaPool node: Bitcoin peers" || die AP-509 "ufw could not allow port 8333 (to manage the firewall yourself: run again with --firewall off)"
  run_q ufw default deny incoming || die AP-509 "ufw could not set deny incoming (to manage the firewall yourself: run again with --firewall off)"
  run_q ufw default allow outgoing || die AP-509 "ufw could not set allow outgoing (to manage the firewall yourself: run again with --firewall off)"
  run_q ufw --force enable || die AP-509 "ufw could not be enabled (to manage the firewall yourself: run again with --firewall off)"
  [ "$was" = 1 ] || kv_set "$STATE" ufw_enabled_by_installer 1
  kv_set "$STATE" ufw_rules "$SSH_PORTS|$STRATUM_PORT|$ALIAS_PORTS|8333"
  say "  ufw: SSH ($SSH_PORTS), stratum $STRATUM_PORT${ALIAS_PORTS:+ $ALIAS_PORTS} and Bitcoin peers 8333 allowed; other incoming denied"
  say "  node RPC (8332) and the gateway admin page (7152) listen on 127.0.0.1 only"
  port_check
}
port_check(){
  [ "$PORT_CHECK" = on ] || return 0
  is_dry && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local res lp=""
  if ! ss -Htln "sport = :$STRATUM_PORT" 2>/dev/null | grep -q .; then
    python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(8); s.settimeout(1.0); end = time.time() + 40
while time.time() < end:
    try:
        c, _ = s.accept(); c.close()
    except OSError:
        pass' "$STRATUM_PORT" >/dev/null 2>&1 & lp=$!
    sleep 1
  fi
  res=$(curl -4 -fsS -m 25 "https://ifconfig.co/port/$STRATUM_PORT" 2>/dev/null | tr -d ' \n')
  [ -n "$lp" ] && { kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null; }
  case "$res" in
    *'"reachable":true'*) say "  outside check: rigs on the internet can reach port $STRATUM_PORT";;
    *'"reachable":false'*)
      warn "an outside check could NOT reach port $STRATUM_PORT on this server. If your provider has a network firewall, allow incoming TCP $STRATUM_PORT there: Vultr: your server > Settings > Firewall (a firewall group needs a rule 'TCP $STRATUM_PORT, anywhere'). Contabo: allow the port in any firewall you added in the customer panel. Rigs on your own network may still connect.";;
    *) say "  outside check of port $STRATUM_PORT skipped (the checking service did not answer)";;
  esac
}

# ==== step 8: start ====================================================================================================
cli(){ timeout 30 /usr/local/bin/bitcoin-cli -datadir="$DD" "$@"; }
step_start(){
  step 8 "Starting the node"
  run systemctl daemon-reload
  if [ "$NODE_CHANGED" = 1 ] && systemctl is-active --quiet knots-node.service 2>/dev/null; then
    say "  the node software or its settings changed: restarting the node"
    run systemctl restart knots-node.service
  fi
  run_q systemctl enable --now knots-node.service || die AP-507 "the node did not start (journalctl -u knots-node)"
  if ! is_dry; then
    local i ok=1
    for i in $(seq 1 120); do cli getblockchaininfo >/dev/null 2>&1 && { ok=0; break; }; sleep 5; done
    [ $ok -eq 0 ] || die AP-507 "the node started but does not answer after 10 minutes (alphapool-node logs node)"
    say_t "  the node is running: block $(cli getblockcount 2>/dev/null)"
  fi
  if [ "$GW_CHANGED" = 1 ] && systemctl is-active --quiet datum-gateway.service 2>/dev/null; then
    say "  the gateway software or its settings changed: restarting the gateway"
    run systemctl restart datum-gateway.service
  fi
  [ -n "$ALIAS_PORTS" ] && { run_q systemctl enable --now datum-port-aliases.service || warn "the stratum port aliases could not be set up"; }
  run_q systemctl enable --now alphapool-gateway-start.service || die AP-507 "the gateway starter did not start (journalctl -u alphapool-gateway-start)"
  rm -f "$ETC/install-in-progress"
  run_q systemctl disable alphapool-install-resume.service
  printf 'ok %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"
  kv_set "$STATE" installed_at "$(date -u +%FT%TZ)"
  say "  install complete: the gateway starts by itself once the node has caught up"
}

# ==== step 9: catching up ==============================================================================================
# count_pool_payees OWN_ADDRESS < the gateway's /coinbaser page: payouts to addresses OTHER than the miner's own.
# Before AlphaPool's payout list arrives the page shows one row paying the whole block to the miner's own address:
# that is the gateway's fallback, not an AlphaPool job, so it counts 0.
count_pool_payees(){ head -c 200000 | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${1:-none}"; }
synced(){   # INFO_JSON
  printf '%s' "$1" | jq -e '.initialblockdownload == false and .blocks == .headers and .headers > 0' >/dev/null 2>&1
}
utxo_fast_start(){
  local f=$DL/utxo.dat info hd avail
  say "  assumeutxo: waiting for the block headers to pass height $UTXO_HEIGHT"
  while :; do
    info=$(cli getblockchaininfo 2>/dev/null); hd=$(printf '%s' "$info" | jq -r '.headers // 0' 2>/dev/null)
    [ "${hd:-0}" -ge "$UTXO_HEIGHT" ] && break
    [ "$(printf '%s' "$info" | jq -r '.blocks // 0' 2>/dev/null)" -ge "$UTXO_HEIGHT" ] && { say "  already past the snapshot height"; return 0; }
    sleep 15
  done
  avail=$(free_bytes "$DL")
  [ "$avail" -ge $(( UTXO_BYTES + 20 * 1000**3 )) ] || { warn "not enough disk for the UTXO file; the node keeps syncing normally"; return 0; }
  fetch_big "$UTXO_URL" "$f" "$UTXO_BYTES" "UTXO snapshot" || { warn "the UTXO download failed; the node keeps syncing normally"; return 0; }
  [ "$(sha_of "$f")" = "$UTXO_SHA256" ] || { rm -f "$f"; warn "the UTXO file does not match its sha256: deleted; the node keeps syncing normally"; return 0; }
  chmod 0644 "$f"
  say "  loading the UTXO snapshot (peer traffic paused meanwhile; 10-40 minutes)"
  cli setnetworkactive false >/dev/null 2>&1
  if timeout 0 /usr/local/bin/bitcoin-cli -datadir="$DD" -rpcclienttimeout=0 loadtxoutset "$f" > "$DL/loadtxoutset.out" 2>&1; then
    say "  loaded: $(tr '\n' ' ' < "$DL/loadtxoutset.out" | head -c 300)"
  else
    warn "loadtxoutset failed ($(tr '\n' ' ' < "$DL/loadtxoutset.out" | head -c 200)); this Knots build may not know height $UTXO_HEIGHT. The node keeps syncing normally."
  fi
  cli setnetworkactive true >/dev/null 2>&1
  rm -f "$f" "$DL/loadtxoutset.out"
}
step_catch_up(){
  step 9 "Catching up with the network"
  if is_dry && [ "${AP_DRY_CATCHUP:-0}" != 1 ]; then say "  DRY: skipped"; return 0; fi
  [ "$SYNC_MODE" = assumeutxo ] && [ "$CHAIN_PRESENT" = 0 ] && utxo_fast_start
  local info b h peers last=0 now t0 judge=120 nap=15
  is_dry && { judge=${AP_DRY_JUDGE_S:-120}; nap=1; }
  t0=$(date +%s)
  while :; do
    info=$(cli getblockchaininfo 2>/dev/null)
    if [ -n "$info" ] && synced "$info"; then say_t "  the node is at the tip: block $(printf '%s' "$info" | jq -r .blocks) ($(( ($(date +%s) - t0) / 60 )) min)"; break; fi
    now=$(date +%s)
    if [ $(( now - last )) -ge 60 ]; then
      b=$(printf '%s' "$info" | jq -r '.blocks // 0' 2>/dev/null); h=$(printf '%s' "$info" | jq -r '.headers // 0' 2>/dev/null)
      peers=$(cli getconnectioncount 2>/dev/null || echo 0)
      if [ "${b:-0}" = "${h:-0}" ]; then
        say "  getting block headers from peers (block ${b:-?}, $peers peers)"; status_set "getting block headers from peers ($peers peers)"
      else
        say "  catching up: block ${b:-?} of ${h:-?} ($(( ${h:-0} - ${b:-0} )) to go), $peers peers"
        status_set "catching up: $(( ${h:-0} - ${b:-0} )) blocks to go"
      fi
      [ "$peers" = 0 ] && [ $(( now - t0 )) -gt 900 ] && say "  no peers yet: check that the server may connect OUT to TCP 8333 (provider firewall)"
      last=$now
    fi
    # Wait here only while the remaining sync is short (the snapshot path: minutes). A node that is far behind (a full
    # sync from the network takes days) or still behind after 90 minutes is left to finish on its own.
    if [ $(( now - t0 )) -ge "$judge" ] && printf '%s' "$info" | jq -e '(.verificationprogress // 0) < 0.95' >/dev/null 2>&1; then
      say "  the node is far behind ($(printf '%s' "$info" | jq -r '(.verificationprogress // 0) * 100 | floor')% verified): a full sync takes days on a small server."
      say "  The gateway starts by itself once the node is at the tip. Progress: alphapool-node status"
      return 0
    fi
    [ $(( now - t0 )) -lt 5400 ] || { say "  still catching up after 90 minutes; the gateway starts by itself once the node is at the tip (alphapool-node status)"; return 0; }
    sleep "$nap"
  done
  is_dry && return 0
  say "  waiting for the gateway to start and get AlphaPool's job"
  local i payees=0
  for i in $(seq 1 60); do
    if systemctl is-active --quiet datum-gateway.service; then
      payees=$(timeout 3 curl -sS http://127.0.0.1:7152/coinbaser 2>/dev/null | count_pool_payees "$ADDRESS")
      [ "${payees:-0}" -gt 0 ] && break
    fi
    sleep 10
  done
  if [ "${payees:-0}" -gt 0 ]; then READY=1; say_t "  the gateway is connected to AlphaPool and has a job ($payees payouts in it)"
  else warn "the gateway has no AlphaPool job yet; check: alphapool-node status (and alphapool-node logs gateway)"; fi
}

# ==== summary ==========================================================================================================
READY=0
public_ipv4(){
  [ -n "$PUBLIC_HOST" ] && { echo "$PUBLIC_HOST"; return; }
  is_dry && { echo "${AP_DRY_PUBLIC_IP:-203.0.113.7}"; return; }
  local ip; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  case "$ip" in ""|10.*|192.168.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
    ip=$(curl -4 -fsS -m 10 https://ifconfig.co/ip 2>/dev/null | tr -d ' \n');; esac   # behind NAT: what the internet sees
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return; }
  echo "<this server's public IPv4>"
}
summary(){
  local host w; host=$(public_ipv4)
  case "$host" in "<"*) ;; *) [ -w "$CONF" ] && kv_set "$CONF" DETECTED_HOST "$host";; esac   # for alphapool-node status
  say ""
  say "=================================================================================="
  if [ "$READY" = 1 ]; then say "  AlphaPool node is READY / AlphaPool 节点已就绪"
  else say "  AlphaPool node installed / AlphaPool 节点已安装 (the gateway starts once the node has caught up)"; fi
  say "=================================================================================="
  say "  Point your rigs at:   stratum+tcp://$host:$STRATUM_PORT${ALIAS_PORTS:+   (or ports $ALIAS_PORTS)}"
  say "  Worker / user:        anything (for example rig1)    Password: anything"
  say "  Payouts go to:        $ADDRESS"
  [ -n "$TAG" ] && say "  Block name:           $TAG"
  say "  Status:               alphapool-node status"
  say "  Logs:                 alphapool-node logs        (install log: $LOG)"
  say "  Stop / start:         alphapool-node stop | alphapool-node start"
  say "  Uninstall:            alphapool-node uninstall   (--keep-chain keeps the chain data)"
  if [ "$HEARTBEAT" = on ]; then say "  Heartbeat:            ON (status only) - turn it off: alphapool-node heartbeat off"
  else say "  Heartbeat:            off - nothing is reported to AlphaPool"; fi
  say "  AlphaPool has no access to this server. Your software, your choice: alphapool-node switch ..."
  say "  ------------------------------------------------------------------------------"
  say "  矿机连接地址:  stratum+tcp://$host:$STRATUM_PORT"
  say "  矿工名/密码:   任意 (例如 rig1)"
  say "  收款地址:      $ADDRESS"
  say "  查看状态:      alphapool-node status      卸载: alphapool-node uninstall"
  [ "$HEARTBEAT" = on ] && say "  关闭状态上报:  alphapool-node heartbeat off"
  say "=================================================================================="
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    say "Warnings:"; for w in "${WARNINGS[@]}"; do say "  - $w"; done
  fi
  if [ "$READY" = 1 ]; then
    issue_set "READY - point your rigs at stratum+tcp://$host:$STRATUM_PORT (worker: anything). Status: alphapool-node status"
    console_note "READY: point your rigs at stratum+tcp://$host:$STRATUM_PORT"
  else
    issue_set "installed; the gateway starts once the node has caught up. Rigs: stratum+tcp://$host:$STRATUM_PORT. Status: alphapool-node status"
  fi
}

# ==== the worker: steps 1-9 ============================================================================================
worker_body(){
  PHASE=install
  install -d -m 0755 "$ETC"
  is_dry && : > "$PLAN"
  touch "$ETC/install-in-progress"
  printf '\n=== AlphaPool node install %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  [ -e "$STATE" ] || : > "$STATE"
  write_resume_unit                    # first, so a reboot at any later point continues the install at the next boot
  step_packages
  step_base
  step_knots
  step_gateway
  step_chain
  step_config
  step_firewall
  step_start
  if is_dry || ! synced "$(cli getblockchaininfo 2>/dev/null)"; then summary; fi
  step_catch_up
  [ "$READY" = 1 ] && summary
  say "=== done $(date -u +%FT%TZ) ==="
}
worker(){
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  install -d -m 0755 "$RUN"
  exec 9>"$LOCK"
  flock -n 9 || { echo "another AlphaPool node install is running (alphapool-node status)"; exit 0; }
  exec >>"$LOG" 2>&1
  [ "$RESUMED" = 1 ] && say "(continuing an install that a reboot interrupted)"
  PHASE=install
  load_settings
  TOKEN=$(head -c 200 "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
  validate_settings
  MEM_MB=$(mem_mb); detect_os; SSH_PORTS=$(kv_get "$CONF" SSH_PORTS || echo 22); [ -n "$SSH_PORTS" ] || SSH_PORTS=22
  software_plan
  [ -e "$DD/blocks" ] || [ -e "$DD/chainstate" ] && CHAIN_PRESENT=1
  [ -e "$DD/.alphapool-restore-in-progress" ] && CHAIN_PRESENT=0
  SELF_COPY=$LIB/install.sh
  worker_body
}

# ==== launching: the install runs as a systemd service, so a dropped SSH session cannot stop it ========================
follow(){   # show the worker's log from OFFSET until it finishes
  local off=$1 pid
  exec 1>&3 2>&4                                # stop writing into the log we are about to read
  trap 'echo; echo "The install keeps running in the background. Progress: alphapool-node status   Log: $LOG"; exit 0' INT
  sleep 1
  pid=$(systemctl show -p MainPID --value "$INSTALL_UNIT" 2>/dev/null)
  if [[ $pid =~ ^[1-9][0-9]*$ ]]; then tail -c +"$(( off + 1 ))" --pid="$pid" -f "$LOG"
  else tail -c +"$(( off + 1 ))" "$LOG"; fi
  case "$(cut -d' ' -f1 "$ETC/last-result" 2>/dev/null)" in ok) exit 0;; *) exit 1;; esac
}
launch(){
  local off
  if is_dry || [ "$FOREGROUND" = 1 ]; then SELF_COPY=$SELF; worker_body; drain; exit 0; fi
  install -d -m 0755 "$LIB" "$RUN"
  install -m 0755 "$SELF" "$LIB/install.sh.new" && mv -f "$LIB/install.sh.new" "$LIB/install.sh"
  local running=0
  exec 9>"$LOCK"
  if ! flock -n 9; then
    running=1; say "An AlphaPool node install is already running on this server: showing its progress."
    say "  now: $(cat "$RUN/install-status" 2>/dev/null || echo starting)"
  else
    flock -u 9
    say ""; say "The install now runs as a background service: closing this window or losing SSH does not stop it."
  fi
  if [ "$FOLLOW" = 0 ]; then say "Progress: alphapool-node status   Log: $LOG   (web console: the login screen shows the state)"
  else say "Showing its progress (Ctrl-C stops watching, not the install):"; fi
  sleep 0.5                                      # let the log's tee write the lines above, then note where it ends
  off=$(stat -c %s "$LOG")
  if [ "$running" = 0 ]; then
    systemctl reset-failed "$INSTALL_UNIT" >/dev/null 2>&1
    rm -f "$ETC/last-result"
    systemd-run --unit="$INSTALL_UNIT" --description="AlphaPool node install" --collect --quiet \
      /bin/bash "$LIB/install.sh" --worker || die AP-508 "could not start the install service (systemd-run)"
  fi
  [ "$FOLLOW" = 0 ] && { drain; exit 0; }
  follow "$off"
}

# ==== uninstall ========================================================================================================
uninstall_main(){
  [ "$(id -u)" = 0 ] || { echo "ERROR [AP-200]: run it as root (sudo)"; exit 1; }
  if [ "$YES" != 1 ]; then
    [ -r /dev/tty ] || { echo "add --yes to uninstall without questions"; exit 1; }
    local ans=""
    { IFS= read -r -p "Remove the AlphaPool node from this server$([ "$KEEP_CHAIN" = 1 ] && echo ', keeping the chain data')? Type yes: " ans < /dev/tty; } 2>/dev/tty || true
    [ "$ans" = yes ] || { echo "Stopped. Nothing was changed."; exit 1; }
  fi
  local u p rules strat al
  for u in alphapool-heartbeat.timer alphapool-heartbeat.service alphapool-gateway-start.service datum-gateway.service \
           knots-node.service datum-port-aliases.service alphapool-install-resume.service alphapool-swap.service; do
    run systemctl disable --now "$u" >/dev/null 2>&1
  done
  is_dry || systemctl stop "$INSTALL_UNIT" >/dev/null 2>&1
  [ -x "$LIB/port-aliases" ] && run "$LIB/port-aliases" delete
  rules=$(kv_get "$STATE" ufw_rules 2>/dev/null || true)
  if [ -n "$rules" ] && { is_dry || command -v ufw >/dev/null 2>&1; }; then
    strat=$(printf '%s' "$rules" | cut -d'|' -f2); al=$(printf '%s' "$rules" | cut -d'|' -f3)
    for p in $strat $al 8333; do run ufw delete allow "$p/tcp" >/dev/null 2>&1; done   # never the SSH rule
    if [ "$(kv_get "$STATE" ufw_enabled_by_installer || true)" = 1 ]; then
      run ufw --force disable >/dev/null 2>&1; echo "ufw: turned off again (it was off before the install)"
    else echo "ufw: the node's rules removed; your SSH rule and your other rules are untouched"; fi
  fi
  for u in alphapool-heartbeat.timer alphapool-heartbeat.service alphapool-gateway-start.service datum-gateway.service \
           knots-node.service datum-port-aliases.service alphapool-install-resume.service alphapool-swap.service; do
    rm -f "$UNITS/$u" "$UNITS/$u.alphapool-new"
    [ -d "$UNITS/$u.d" ] && echo "note: your drop-in folder $UNITS/$u.d was left in place"
  done
  run systemctl daemon-reload
  rm -f /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli "$CLI_BIN" /etc/needrestart/conf.d/alphapool.conf \
        /etc/issue.d/alphapool.issue /var/lib/alphapool-swapfile
  rm -rf "$LIB" "$DL" "$RUN" "$ETC"
  if [ "$KEEP_CHAIN" = 1 ]; then
    rm -rf "$GWD"
    echo "kept: the chain data in $DD (user $U). A new install on this server reuses it."
  else
    if id -u "$U" >/dev/null 2>&1; then userdel -r "$U" >/dev/null 2>&1 || { rm -rf "$HOME_U"; userdel "$U" 2>/dev/null; }; fi
    echo "removed: the node user $U and all chain data"
  fi
  echo "uninstall $(date -u +%FT%TZ)" >> "$LOG"
  echo "The AlphaPool node was removed. Left in place: the system packages it installed ($PKGS) and the log $LOG."
}

# ==== cloud-init / startup script ======================================================================================
sq(){ printf "'%s'" "${1//\'/\'\\\'\'}"; }
print_cloud_init(){
  local url=${CI_URL:-$INSTALLER_URL} sha args body
  [[ $url =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=,@-]*$ ]] || { echo "ERROR [AP-130]: --installer-url is not a URL"; exit 1; }
  sha=$(sha_of "$SELF")
  args="--yes --no-follow --address $(sq "$ADDRESS")"
  [ -n "$TAG" ] && args="$args --tag $(sq "$TAG")"
  [ "$STRATUM_PORT" != 23334 ] && args="$args --stratum-port $STRATUM_PORT"
  [ -n "$ALIAS_PORTS" ] && args="$args --alias-ports $(sq "$ALIAS_PORTS")"
  [ "$HEARTBEAT" = on ] && args="$args --node-id $NODE_ID --token-file /root/alphapool-node/heartbeat.token"
  body=$(cat <<EOS
exec >>/var/log/alphapool-node-cloudinit.log 2>&1
set -u
d=/root/alphapool-node; mkdir -p "\$d"; chmod 700 "\$d"; cd "\$d" || exit 1
command -v curl >/dev/null 2>&1 || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates; }
for i in \$(seq 1 30); do curl -fsSL --retry 3 --connect-timeout 20 -o ap-node.sh.part '$url' && mv -f ap-node.sh.part ap-node.sh && break; sleep 20; done
if ! echo '$sha  ap-node.sh' | sha256sum -c -; then
  for t in /dev/tty1 /dev/ttyS0; do [ -w "\$t" ] && echo "AlphaPool node: the downloaded installer does not match its sha256: NOT run" > "\$t"; done
  exit 1
fi
EOS
)
  if [ "$HEARTBEAT" = on ]; then
    body="$body
(umask 077; printf '%s\\n' '$TOKEN' > heartbeat.token)"
  fi
  body="$body
bash ap-node.sh $args
rc=\$?
rm -f heartbeat.token
exit \$rc"
  if [ "$CI_FORMAT" = script ]; then
    printf '#!/bin/bash\n'
    ci_header
    printf '%s\n' "$body"
  else
    printf '#cloud-config\n'
    ci_header
    printf 'write_files:\n  - path: /root/alphapool-node-start.sh\n    permissions: "0700"\n    content: |\n'
    printf '%s\n' "$body" | sed 's/^/      /'
    printf 'runcmd:\n  - [bash, /root/alphapool-node-start.sh]\n'
  fi
}
ci_header(){
  cat <<EOS
# AlphaPool node, installed by itself at the server's first boot. Paste ALL of this text into the provider's
# cloud-init / user-data field when you order the server (Ubuntu 24.04 or 22.04 x64): Vultr "Cloud-Init User-Data",
# Contabo "Cloud-Init". It downloads AlphaPool node installer $AP_VERSION and runs it ONLY if its sha256 is
#   $(sha_of "$SELF")
# Progress: the provider's web console (the login screen shows it), or after SSH login: alphapool-node status
EOS
  [ "$HEARTBEAT" = on ] && cat <<'EOS'
# The heartbeat token below is stored by your provider and readable by programs on the server (cloud metadata).
# It only lets its holder report status for this node; to keep it out, drop --node-id here and turn the heartbeat
# on after the first login instead: sudo alphapool-node heartbeat on <node id>
EOS
  return 0
}

# ==== main =============================================================================================================
SELF=""
main(){
  SELF=$(readlink -f "${BASH_SOURCE[0]}")
  case "$DRY" in 0|1) ;; *) echo "AP_DRY_RUN must be 0 or 1"; exit 2;; esac
  if is_dry && ! in_container; then echo "ERROR [AP-201]: AP_DRY_RUN=1 only runs inside a throwaway container"; exit 1; fi
  parse_args "$@"
  case "$MODE" in
    help) usage; exit 0;;
    version) echo "AlphaPool node installer $AP_VERSION"; exit 0;;
    worker) worker; exit $?;;
    uninstall) uninstall_main; exit $?;;
    check)
      apply_flags; check_address "$ADDRESS" || { echo "address: $ADDR_WHY"; exit 1; }
      echo "address ok: $NORM_ADDR"
      if [ "$A_TAG_SET" = 1 ]; then check_tag "$TAG" || { echo "block name: $TAG_WHY"; exit 1; }; echo "block name ok: $TAG"; fi
      if [ -n "$NODE_ID" ]; then uuid_ok "$NODE_ID" || { echo "node id: not a uuid"; exit 1; }; echo "node id ok"; fi
      exit 0;;
    cloudinit)
      apply_flags; read_token
      check_address "$ADDRESS" || { echo "ERROR [AP-101]: $ADDR_WHY"; exit 1; }; ADDRESS=$NORM_ADDR
      if [ -n "$TAG" ]; then check_tag "$TAG" || { echo "ERROR [AP-102]: $TAG_WHY"; exit 1; }; fi
      port_ok "$STRATUM_PORT" || { echo "ERROR [AP-103]: bad --stratum-port"; exit 1; }
      if [ "$HEARTBEAT" = on ]; then uuid_ok "$NODE_ID" && token_ok "$TOKEN" || { echo "ERROR [AP-110]: --node-id needs a uuid and a 64-hex token"; exit 1; }; fi
      case "$CI_FORMAT" in cloud-config|script) ;; *) echo "ERROR [AP-130]: --format is cloud-config or script"; exit 1;; esac
      print_cloud_init; exit 0;;
  esac
  [ "$(id -u)" = 0 ] || { echo "ERROR [AP-200]: run it as root: put sudo in front of the command (sudo bash ap-node.sh ...)"; exit 1; }
  install -d -m 0755 /var/log; touch "$LOG"; chmod 0640 "$LOG"
  start_tee
  printf '\n=== AlphaPool node installer %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  load_settings
  apply_flags
  read_token
  validate_settings
  detect_os
  software_plan
  preflight
  show_plan
  confirm
  save_settings
  launch
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
