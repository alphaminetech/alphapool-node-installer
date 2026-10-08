#!/bin/bash
# AlphaPool node installer: Bitcoin Knots + a DATUM gateway on a server YOU own, mining with AlphaPool.
#
#   sudo bash ap-node.sh --address <your payout address> [--tag "<block name>"] [--yes]
#   bash ap-node.sh --help        all options. README.md explains every step, every file and how to undo it.
#
# Needs Ubuntu 22.04 or 24.04 LTS (x86_64), 4 GB RAM and 80 GB disk. It installs:
#   * Bitcoin Knots as a pruned node: the node that builds your blocks (the version is pinned below)
#   * AlphaPool's DATUM gateway: makes block templates from YOUR node; your rigs connect to it (pinned below)
#   * the validated start for the chain: the node loads a UTXO snapshot that Bitcoin Knots itself checks against a
#     hash compiled into it, then validates every block since then by itself (README "How the node gets its chain")
#   * a firewall that keeps your SSH port open, lets rigs and Bitcoin peers in and keeps everything else closed
# Every download is pinned below (https URL + sha256) and checked BEFORE it is used. Bitcoin Knots is also checked
# against its release builders' signatures for the official mode; the fast developer build is sha256-pinned only.
#
# AlphaPool gets NO access to this server: no SSH keys, no allowlists, no remote commands, no update channel.
# Your SSH setup is not touched. The optional status heartbeat (only with --node-id and --token) reports sync and
# mining status to your AlphaPool dashboard, never passwords, keys or configs. Turn it off: alphapool-node heartbeat off
#
# Your node, your software: --gateway-* and --knots-* install other builds, `alphapool-node switch` changes them
# later, and re-running this installer never replaces a build you chose or a file you edited by hand.
# Upgrade in place (no resync): download the new installer, then  sudo bash ap-node.sh --upgrade
# Is a newer installer published? `alphapool-node upgrade check` says so and runs nothing; `alphapool-node upgrade
# <sha256>` downloads it, refuses it unless its sha256 is the one you give, then runs --upgrade. Nothing updates by itself.
set -uo pipefail
umask 022
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

AP_VERSION="2026-10-09.1"
INSTALLER_URL="https://xbt.alphapool.tech/node/install.sh"     # what --print-cloud-init fetches (and verifies)

# ==== Pins: AlphaPool's tested software. They change only with a new installer release (= a new sha256 for it). ====
# ---- Start modes: the Bitcoin Knots build a node runs, and the UTXO snapshot a new node starts from ------------------
# A new node loads a UTXO snapshot (the set of all unspent coins at one block), validates every block since then by
# itself, and checks the whole history before the snapshot in the background. A Bitcoin Knots build takes a snapshot
# only at the block heights compiled into it, and it checks the snapshot's content against a hash that is compiled in
# as well. So a way to start is a pair: a Bitcoin Knots build, and the snapshot it starts from. That pair is a START
# MODE. (AlphaPool's pre-synced copy of a node's chain folders, the start of installers before 2026-10-08.1, is gone:
# a node validates its chain itself.)
# start_modes has one line per mode, fields separated by "|":
#    1 name                what --start takes
#    2 Knots version       what `bitcoind -version` of that build says
#    3 archive URL         the x86_64-linux-gnu archive of that build
#    4 archive sha256
#    5 who vouches for it  builders = the release's SHA256SUMS must carry a valid signature of a pinned Bitcoin Knots
#                                     release builder AND list the archive, and the archive must match the sha256
#                          pin      = the sha256 alone: a build the release builders have NOT signed (a developer build:
#                                     the official source with a change). The installer says so wherever it names the mode
#    6 snapshot heights    the block heights compiled into that build, space separated
#    7 start height        the snapshot a new node starts from (its file is in utxo_table below)
#    8 duration            how long the node then validates blocks on a small server; every text takes it from here
#    9 label               how the installer and the dashboard call the mode
#   10 what you trust      one sentence in English
#   11 Chinese notice      optional translation of that sentence
# START_DEFAULT is the mode of a new install; --start NAME takes another one. START_LEGACY is the mode of nodes that
# were installed before modes existed (they run the official release). Another Bitcoin Knots release, a newer
# snapshot or another mode is a change of these lines and of utxo_table, and of nothing else. Nodes that are installed
# keep their mode and their chain; `alphapool-node upgrade` moves them to their mode's build in the new installer.
START_DEFAULT="fast"
START_LEGACY="official"
# A Bitcoin Knots release that EVERY node must run from a given block (new consensus rules: a soft fork). Empty until
# such a release exists; the installer release that pins it fills both values. From then on `alphapool-node status`
# shows an UPDATE line on a node whose bitcoind is not that release, the installer and the upgrade warn, and the
# heartbeat reports the installed versions so the dashboard can show who still has to update.
KNOTS_REQUIRED_VER=""
KNOTS_REQUIRED_BY_HEIGHT=0
start_modes(){ cat <<'MODES'
official|29.4.2.knots20260508|https://bitcoinknots.org/files/29.x/29.4.2.knots20260508/bitcoin-29.4.2.knots20260508-x86_64-linux-gnu.tar.gz|b59d0445a317e21a03dc29425db3aba79b27d5125230b1a2b1dce62e120827c5|builders|840000 880000 910000|910000|one to two days|the official Bitcoin Knots release|You trust the Bitcoin Knots release builders: the installer checks their signatures on this release, and Bitcoin Knots checks the snapshot against the hash that is part of that release.
fast|29.4.2.knots20260508|https://github.com/chrisguida/bitcoin/releases/download/v29.4.2.knots20260508-assumeutxo976000/bitcoin-6ce57028d6cf-x86_64-linux-gnu.tar.gz|5c26890d72daa499fe22b905de5cfb0a78e2445aedbde0726278f57672106a9d|pin|840000 880000 910000 976000|976000|about half an hour|a developer build of Bitcoin Knots with the 976000 snapshot|This developer build is pinned by its sha256 and is not signed by the release builders; when the signed release includes this snapshot, the upgrade command moves your node to that release.|这个开发者构建版按 sha256 固定，发布构建者没有为它签名；当签名发布版包含同一快照后，升级命令会将您的节点升级到该版本。
MODES
}
# utxo_table: the snapshot files, one line each:
#   <height> <hash of the block at that height> <file name> <bytes> <sha256 of the file> <URL> [<info hash> [<.torrent URL>]]
# The file's sha256 is checked before the node sees the file; the node then checks the content itself. Lines that start
# with # are not used. Fast starts at 976000; the signed official mode retains its 910000 snapshot.
# Columns 7 and 8 are optional: the BitTorrent info hash of the file (40 hex; tools/make-torrent.py prints it) and the
# URL of its .torrent file. With an info hash the download comes over BitTorrent first (other installing nodes and the
# seeders share the load; the https URL is the fallback), and the node seeds the file for a while afterwards. The
# .torrent file, if given, is used only when its info hash is the pinned one; without it the magnet link is built from
# the info hash and the trackers below.
utxo_table(){ cat <<'TABLE'
910000 0000000000000000000108970acb9522ffd516eae17acddcb1bd16469194a821 utxo-910000.dat 9637809744 6ac0208110d6d6c0783c50ea825aae32f5229cf1dcb63ac986543e95aa0306bf https://snapshots.alphapool.tech:8444/xbt/utxo-910000.dat
976000 000000000000000098441aee029573795681eb1602c75271e809b136e9217373 utxo-976000.dat 9517597408 bfd2460a55ae1d2e94b9957ccd512ae027855feed1dbef996cfed0abebe5d123 https://snapshots.alphapool.tech:8444/xbt/utxo-976000.dat 3cf7e4d15841f116856f6f19bf2ac15b1dbae2c3
TABLE
}
UTXO_TRACKERS="udp://tracker.opentrackr.org:1337/announce udp://open.stealth.si:80/announce udp://tracker.torrent.eu.org:451/announce udp://exodus.desync.com:6969/announce"
UTXO_SEED_MINUTES=120     # after the download: seed the snapshot to other installing nodes for at most this long (share ratio 2)
# The Bitcoin Knots pin of this run is the build of the node's start mode: mode_apply sets these four (and M_*).
KNOTS_VER=""; KNOTS_URL=""; KNOTS_SHA256=""; KNOTS_VERIFY=""
M_NAME=""; M_VER=""; M_URL=""; M_SHA=""; M_VERIFY=""; M_KNOWS=""; M_HEIGHT=""; M_ABOUT=""; M_LABEL=""; M_TRUST=""; M_TRUST_ZH=""
START_MODE=$START_DEFAULT
mode_names(){ start_modes | awk -F'|' '$1 !~ /^#/ && NF >= 10 {printf "%s%s", s, $1; s=" "}'; }
mode_load(){   # NAME -> M_*. 1 = this installer has no such start mode, or its line is not well formed
  local line
  line=$(start_modes | awk -F'|' -v n="$1" '$1 == n && NF >= 10 {print; exit}')
  [ -n "$line" ] || return 1
  IFS='|' read -r M_NAME M_VER M_URL M_SHA M_VERIFY M_KNOWS M_HEIGHT M_ABOUT M_LABEL M_TRUST M_TRUST_ZH <<<"$line"
  [[ $M_NAME =~ ^[a-z][a-z0-9-]{0,19}$ ]] && [[ $M_VER =~ ^[A-Za-z0-9._-]+$ ]] \
    && [[ $M_URL =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=,@-]*$ ]] && [[ $M_SHA =~ ^[0-9a-f]{64}$ ]] \
    && [[ $M_VERIFY =~ ^(builders|pin)$ ]] && [[ $M_HEIGHT =~ ^[1-9][0-9]{0,8}$ ]] && [[ " $M_KNOWS " == *" $M_HEIGHT "* ]] \
    && [ -n "$M_ABOUT" ] && [ -n "$M_LABEL" ] && [ -n "$M_TRUST" ]
}
mode_apply(){   # the Bitcoin Knots build of START_MODE becomes this run's pin. 1 = no such mode
  mode_load "$START_MODE" || return 1
  KNOTS_VER=$M_VER; KNOTS_URL=$M_URL; KNOTS_SHA256=$M_SHA; KNOTS_VERIFY=$M_VERIFY
}
mode_apply || { echo "ERROR: this installer's own table of start modes is not well formed (START_DEFAULT=$START_DEFAULT)"; exit 2; }
# bitcoin-cli of every Knots archive an AlphaPool installer has pinned: "<archive sha256>:<bitcoin-cli sha256>" (space
# separated). Installers before 2026-10-07.2 recorded bitcoind's sha256 only; this list tells their untouched bitcoin-cli
# from one you replaced yourself, which an upgrade must leave alone.
KNOTS_CLI_KNOWN="b59d0445a317e21a03dc29425db3aba79b27d5125230b1a2b1dce62e120827c5:93b97943d9cc5784670e0106e0127879833871d56459e6919e7b01df6dc9a9b8"
# AlphaPool's DATUM gateway. The download's sha256 is checked before it is unpacked, the binary's after. A newer
# gateway build is a change of these lines and nothing else (GW_VER, GW_GIT_URL + GW_GIT_COMMIT, and URL + two sha256
# per Ubuntu release): `alphapool-node upgrade` then moves every node to it, together with Bitcoin Knots, in one step
# with a way back. The gateway's settings and its identity key are not touched by that.
GW_VER="3.1"                    # the label status and the upgrade show ("release <GW_VER>")
# The public source of the pinned build: repository and commit. The two are set together with archives that are built
# from that commit (such a build sends the commit to the pool as its version). While both are empty, no text of the
# installer names a source: the archives below are release 3.1 as it was built before its source was published.
# tests/gateway_pin.py writes these eight lines from the files of a publication; nothing is typed in.
GW_GIT_URL="https://github.com/alphaminetech/datum_gateway.git"
GW_GIT_COMMIT="90f01b76625f5936febdc2389759c462467a750a"
GW_URL="https://snapshots.alphapool.tech:8444/gw/datum_gateway-r3.1-g90f01b76625f-noble.tar.gz"
GW_TAR_SHA256="85e5131c272418bf1c12a59802aaea58a902f020c6e9a25bbb46c1ff8b3d14ed"
GW_SHA256="02ca5e7b78c4bd89b97ab385932a6f7baecb0c77bc023f5a57d06d956a336792"
# Ubuntu 22.04: the same source built there (the build above needs glibc 2.38; 22.04 has 2.35). The installer picks
# the build by VERSION_ID.
GW_JAMMY_URL="https://snapshots.alphapool.tech:8444/gw/datum_gateway-r3.1-g90f01b76625f-jammy.tar.gz"
GW_JAMMY_TAR_SHA256="93fe865c5ecedb30886e16ce9ae8943b3a88218f362af078608a9f6caa19d15c"
GW_JAMMY_SHA256="52367405588d48138a972f871624fe9da88df350bec6ebc03d4d83e954f3b043"
# A node keeps the build it has until `alphapool-node upgrade` moves it to the build pinned here. Archives that an
# earlier installer pinned stay on the download server: that installer still checks them by their sha256.

# The chain. Every release says "main". The test suite runs this same file on a small private chain (regtest) by
# changing these three lines in its copy.
NODE_CHAIN="main"
NODE_NET_MAGIC="f9beb4d9"       # the first bytes of every message, and bytes 8-11 of every UTXO snapshot file, of that chain
NODE_CONF_EXTRA=""              # extra bitcoin.conf lines (\n between them); empty in every release

# ==== Bitcoin Knots release builders ==================================================================================
# A Bitcoin Knots archive is installed only if the release's SHA256SUMS carries a valid signature from at least one of
# these keys AND lists the archive (and, for a build this installer pins, the archive also matches its sha256 in
# start_modes above). A start mode whose build is vouched for by "pin" is the one exception, and it is named as such.
# Source of every key and fingerprint: the official builder-keys directory of the Knots release signatures,
#   https://github.com/bitcoinknots/guix.sigs   branch knots, commit 278e3aeac8ce78c915940b25b3c3bcb9c9f0598e (2026-09-21)
#   builder-keys/*.gpg ; each line below: primary-key fingerprint, then the sha256 of its key file in that directory.
# These are the 7 builders whose signatures are on the 29.4.2.knots20260508 release (SHA256SUMS.asc, bitcoinknots.org).
#   1A3E761F19D2CC7785C5502EA291A2C45D0C504A  c82ce3a2038cb36ad50aa59e16e42ce5ab4d11ccc6f1a58a71f83c5361974316  (Luke Dashjr, Knots maintainer)
#   658E64021E5793C6C4E15E45C2E581F5B998F30E  f11f6c1807c15fc48adaf87da383275d63866f897600bafb6e87fee369282963
#   95636F3538D9262765AB29BEE952E584CA8C0F45  5c3535dad3a31a05b72e54a1e8eab97363e3d645ef7d24a99d5ec098b2332965
#   314B8D611A0C0468498C35C52018C90B857A0571  48973dcd02a5a62af0d574470afe954f8896514dbce0d7d2fa3750a79ce74858
#   1D5889CB9E0564C154E18BB512EC9519DB43CC27  18ac4000bdc04a211ae3fcac833be78965fea6968b763f7cde5f42c0f6397120
#   A47D99B6DB0D715D40C59A2023AE8A8EA7E24E38  1e6c0f1f30300285c0597e2411e4827b6f48e2da37cbe76ffe7f36260ef05f8d
#   DAED928C727D3E613EC46635F5073C4F4882FFFC  0b060ee7c9a1ea69dc1922b36a4205c21ef223e374afcbabdc8c356bd8bba9c9
KNOTS_BUILDER_FPRS="1A3E761F19D2CC7785C5502EA291A2C45D0C504A 658E64021E5793C6C4E15E45C2E581F5B998F30E 95636F3538D9262765AB29BEE952E584CA8C0F45 314B8D611A0C0468498C35C52018C90B857A0571 1D5889CB9E0564C154E18BB512EC9519DB43CC27 A47D99B6DB0D715D40C59A2023AE8A8EA7E24E38 DAED928C727D3E613EC46635F5073C4F4882FFFC"
# The 7 keys themselves (gpg --export --export-options export-minimal, base64): the installer needs no keyserver.
knots_keyring(){ base64 -d <<'KEYS'
mDMEY/qPOhYJKwYBBAHaRw8BAQdAOZ14+e7eu4f41o3aXFc0oanZ17u5TrtZ5wSPv/vdlla0M0x1a2UgRGFzaGpyIChDb2Rlc2lnbmluZykgPGx1a2Ut
anIrZ2l0QHV0b3Bpb3Mub3JnPoiZBBMWCgBBAhsDBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAFiEEGj52HxnSzHeFxVAuopGixF0MUEoFAmnNk7EF
CQe0N/cACgkQopGixF0MUEpFKAD+M/3+snUPxp5ul2avi1P81AKrbZr8BcyLwi8tcCWcMOkA/3DcvcEeUU36YmaLp/znwud3yeJsJeehZbZjp40tjI8C
uDgEY/qPOhIKKwYBBAGXVQEFAQEHQCNSV2aR3hmwCLcElLQShHFerZNCU8SiVHKDJ1ML8k1LAwEIB4h+BBgWCgAmAhsMFiEEGj52HxnSzHeFxVAuopGi
xF0MUEoFAmnNk9QFCQe0OBoACgkQopGixF0MUEp8BAD+LzmHgY7X4s8q2tslQTODBeNjlU9awEQdJBY55E33FyMA/1GGoYO2euIPjEf/CClyfiZeoIBU
wvxFHBsY/ndl0aMBmDMEZrZiNBYJKwYBBAHaRw8BAQdAUYm10pBtfSDwuMAnFyjdtrtyb3vsBNYZk/5tVs2SKqu0IkNocmlzIEd1aWRhIDxjaHJpc2d1
aWRhQGdtYWlsLmNvbT6IlgQTFgoAPgIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgBYhBGWOZAIeV5PGxOFeRcLlgfW5mPMOBQJqkGGHBQkHnGZTAAoJ
EMLlgfW5mPMOs2sBANJ434Gm9cnBt5OjPIOH5+8Xt3K1hXJdbabAa9qcJHgzAQDn6c/w4s4iKM1+582yy9UFD4TrMmeVPjbYVOy6ZspEC7g4BGa2YjQS
CisGAQQBl1UBBQEBB0A99GaIU+mhHxrF5+dsxjm5G+wiGFxWvHdr/mlMpGBfYQMBCAeIfgQYFggAJgIbDBYhBGWOZAIeV5PGxOFeRcLlgfW5mPMOBQJq
kGKLBQkHnGdXAAoJEMLlgfW5mPMOOU0A+gM3s+TMmCiB+4uk248ofF2c69xUdv3gDXaCxX0VYA6FAP9JEOW3I9gp6HU2odirom6Jw3rpDKvaanyn2fcB
rYxcDZkCDQRmP7a6ARAA7AMinb+BEYvuNoHIuYUxFDgtivXFZVX1WMbotZQtVyssfsSPIjT/F8hnfjJbhkkq910EESPet0oxbTbBaBGd0VFxpOF0mUFU
cYVKWlKoKhZ9uZxnMVDR+qv7ellj+q3WFjCg8x11AzLrGVTqfBGQmOBzMr76nP0cfNef9RqgHqYHEkAA9dSuEEtEQsZNF57650Dxb64hFtB3+ApSbMfA
VNj7kA2BQzjQt92ST0S40/PSc1uKmUwh+gd8aVvZA0Rv1MHToJBgW68XQlvm9xpUH4odYICI1nGntaD/Zpbt8zNI8APGeomSsvcRXvnHhatTzUBa6d41
JSojX/j5Xkzoisg1K4wAb4eAbg8/jtUdkahem/NgvZ9cFHR55uyMdlfkpfSvLXAT4ozJKjj4TLDGbmWjjt9wWp2e42ySPSZ3auMg9Kxxc8Zg+8DMYNPb
b5pJtjKwVuQl0Scv4GI9z3gs+2Ormvu5bjzoAh3TohVDz6G2z2mvqYzFUIQJsk7ayEPS05t+h7z+3+I6+uTCd4IfKGX3FjIbfFd8R4Z99tfaHErt0LbF
OTrk4/j0OxKWmyaLk1lnUKophevtmgiiizCiF1zo87AdZNBq4Sy6mg1f9Rv0a/shenIU+Uzfq37s9jkLy9QyHH9JrC+o1wtutPK4QfnK2aDLbXKgtGP+
LLm+g1kAEQEAAbQrYml0Y29pbm1lY2hhbmljIDxiaXRjb2lubWVjaGFuaWNAb2NlYW4ueHl6PokCTgQTAQgAOBYhBJVjbzU42SYnZaspvulS5YTKjA9F
BQJmP7a6AhsDBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEOlS5YTKjA9FF5EQAICldgHpkzDTb5lK6Yl59bP6oz+ty1aKX5ZU4L7r7zL10MBdzhj7
eofT+sQTcj0QgtZPFqPlRc2fFpqMB6kRLFp5ntHR5KcqkF/2fvX/JCrAu6w705rXrc1IqkWcCMmGewlzMToj/UyxD7sXDbd+P1EycDO3nJoRu59S5yVN
PvgJiQ6IJ7pnBjHhLMuxkgx/RAE+mWss0GlPSFLu0n9eEo4hAo8FCC069dk3G4E7cxSer5fHPQjvKsiH3364atfT6EeHu6eXA4tf9FCSeBNS3qrOwjfY
0fpBRaYWr91d3m1lPrIqjg5h2kcGrRyQPu+mcxi1aSNsIzAfq56I7n2E4YnAdeTgg96+jU0LIEwjRlomOQbqQa+8W76KufS/xv14XMeQvziXY4ViN6i+
VFwM5MAjUh3YRVwS6aR6SfHGsmljPiKoRrCXX0jKlwiBHSVaOtx+hc5+0879Bll20KSiQcTUC6bvlkNrCJya2gXCVpeT1Y4bFs66OjbuId6PHV3idllb
J9oOhf9z7Vs90E65OIqGmIV3pu3kDjBLR3/AOHiqoEtVlTCdN7c5i5GBGhBLHsDXSO4h6BS1mew/TRWdM14T3iFwgo9QpJD3BbMj8esW5F9ne3TIJ1on
Lp4HyoKRDfXtJwVaNrR/yS/nF1C04NmTcgPAZSVLWR9xwjzkwzcAuQINBGY/troBEADH8mq4T3kxCDA02MNcGlpQXY/HdY1sljbjVThl/V5bkgjv6r2Z
6T1IvTZzBbS3lrSxhmby8fQEWxyW3EytOm7+yB/NrV1PAIsMsxbODG3u++hnS8vmRrhzy+15vkSVBBup9Z4QRv8yGdWqp/l5ccGkHGfCbwAlyJhJoKbi
NjNm6PZaGlflasVwx4PyL75v/9PbvVXY/5A+58Y3VZwCcpfK0tHJWB+KhBPui4YpUFRl52UTdhf83dAnOJKHgV90vu0lQ4p2aSibw9vKOoU9nXgrXKxj
C11jwmflTuBkbPmE7fI83t5+HZm2MpoEzbK0XHqA/x2g0ndzcPiS/cOjti5XsMwKGO8611QwpQ8YZHdatRMPWv8AftRWyPcBcuKr7dzV8Rv5cYLzq9BI
0RwbjroO83b0v6izXnrCvhClZFueTHSDeE7BWxH/aHBux/inaX4uLaYW4EBSEFa7X/YPM2u3V1WIiaVNBMcFN3IbjhGgK+qIydjoWc0anPNscW/eUZZd
xp6FrPG5lx4yvZGdf0t+p77PKXhEP0yMlHOwUrNepBOMLlJNxT/qJ/BRL1xd3WqSfVL0XWlpStVGxRkECCJV+pGQzbfdNv1ocRQu/AXzlTHe/Y68wUKP
pHaYu3a/JrJDIt0M5oesQ6ucojvKE+mvBT8Nw/IabxXyBa0dCEHorwARAQABiQI2BBgBCAAgFiEElWNvNTjZJidlqym+6VLlhMqMD0UFAmY/troCGwwA
CgkQ6VLlhMqMD0V28xAAgYzBHwI5ZDA0lbqfygJyxaQHcs2jPBdggrafNNQI33TKTnOJl73W02npg+yiEmMcBxGOTozBOR/Wb+3ssX7bh/6S8GweUzrk
j5N1/d850+C8dGDilzfrXTbs+33XFfulXlS26Uv58RusBSkKnyd4tA7yuKvL1W5ExIGzu2rMVMKBM0cyikNawn5JSdPGFzvyCBG6iO7MtHRV94yJfnaQ
fe0Vl27tSc5/hP3/EHPrqxavja+3ChqpHeSO3b9X1Wv3oMi/OD6a+3xIYDW+P52WDkuuOeJKSKFWxgL/1g05QwY5csjlfysfhG1U/YoPBDoe0lgv60Be
MxVKcGp7J+BXEFR1OCuISdjsyOGLj/Sl39QQrpCsVU4SIGFHzCzIMTIF5YqjmJSiXRP9oPNqJCaG/bTNUwgSpTYzsbwmzEVvwpmXQmGcrjE5qXD+Xen7
xcKZOvYxWPmHCsqvUGGtDnt8qLyez2CvaIOE+WRrUUURZhhe+G1jwGXCmphslOxnooXJQfAwObwEK14l8vMRJ/GURkahRJ2w0z3HGpWENsVd9d1ltxpu
dyf8JLBOkdYHIf6qFuucXSCDpVL8Z6mMVnLHFStfenTdObWCHBaBt7o6haQIRrESoLqqcEhHliGsSOTXSR2LEkYIjeNfiPW0vPygFUjyq8dZHy162T2K
mxCLfVGYMwRql43nFgkrBgEEAdpHDwEBB0DGMHUweYk+bjjPKAQ7XEzIu3tQQM/Irqw5FLkK5kUxJbQnaW5uZXJoYXQtZGV2IDxqdXN0aW4uZmlsaXBA
b3V0bG9vay5jb20+iK8EExYKAFcWIQQxS41hGgwEaEmMNcUgGMkLhXoFcQUCapeN5xsUgAAAAAAEAA5tYW51MiwyLjUrMS4xMiwwLDMCGwMFCwkIBwIC
IgIGFQoJCAsCBBYCAwECHgcCF4AACgkQIBjJC4V6BXExCgD/bVlc2yaB13anUph4SLjrQ7nG0hg+EmSCmur/AvaWaVABANEjS2Kcp//YxS98XmpXvMqn
GJqif6xS6s0AbmocDx8JuDgEapeN5xIKKwYBBAGXVQEFAQEHQAfc0OpS9sinRYjhHTJUBeaVLq1iFpZPIMyUR/CYxclSAwEIB4iUBBgWCgA8FiEEMUuN
YRoMBGhJjDXFIBjJC4V6BXEFAmqXjecbFIAAAAAABAAObWFudTIsMi41KzEuMTIsMCwzAhsMAAoJECAYyQuFegVxl9kA/0DLPQI5tNIcRE0NGria+1Ej
QJzjsQX6u8Y3bCW+PW6EAQCglt0cUrhQuYZyYhgSe9aKz34kajAd72J6tpv2JJ2LBZkBjQRo2vbqAQwAq5laGNChxz30PKBuu0O51j5Eli+tdImsDeRG
g2f/oa1pj06kwIJhY/4qsOAiH4pYuuDTlpQe5xjcP6FEtcQWFy6QHuMfbiB2lBsFbgCgXjmnHWJDWZ7Zkd2KpWFLX032Hi4rAj0YHJEEq3fxUZQacLiA
YzaZVSwb3hZ/sRl7vKYfJYVrzp7wDW47E2Q/ZZmXdYKHzXHS+xHmsxfXIgCrFnLqclbeMUPeIUNX4uLLbQp7EYDef3vmqO7zFq0/FyUI//kOu49ebYnc
SFH9jNnVvTYYYDUbOV+jojIHYHFhvHs/7v6544hfXRc4VaB7R7ODwW6Ic/DtZKsiPWvD4BCcUiNzAr3rLCuQTYD4HHNPPVI2KHNNBCgVHEpoKP2p0qYi
jaGx6CT0Z044S4hKpNSB+JgDjo8ti5R+JDQuBiD7BkhVAmDhrbsycuiiJadXjoFjY8iGAuVjchPS4KTdhKUGMGnTWH2FHhPM/Y7fswKXlH0DJLZDKpH+
YgefdKdvvFEDABEBAAG0JU1hcmsgSCBSdXNzZWxsIDxtaHI2MDkxQHR1dGFtYWlsLmNvbT6JAdEEEwEKADsWIQQdWInLngVkwVThi7US7JUZ20PMJwUC
aNr26gIbAwULCQgHAgIiAgYVCgkICwIEFgIDAQIeBwIXgAAKCRAS7JUZ20PMJzdgC/4owdfsKIwiqHv+vkAPeB1udi5zJFZ8HJZIrWeeNEy9VEFeEuQD
SbmSVgNR3AXay8s0CRh1fbeO8eH229jPgRQeg/2otyUdln8BF6LmIJDFjYmiCE6NlK410seZxcMqrJbWXRkdW4AVeNrGUpF1v5N9ho0AxWsw6nebya4j
ZjW083cDl6w0U6hjqnJ/RglMaxqCVolFj8zNle54/LJ59SOZaFpDu+4kVFkH7f0lU+xviWVSb8YC2UjuSz3Loy8m3MtPXxAP7rfP7TdjmTBd6ANSZLf4
HV6cVo6gvGZ4DGj5B1UEpz6nuhYNIDIxsCo+R8yh7IvWX4iq3SvGOh6Lr+Lg+P797VOl2cvhXIem5ri3vfOkiL/+kbOqtHzAVc4xljSkdYXTb/AOXaqa
TET78LCbxXIZ7vftFcdDj6uD5NJnn05FXF1KmrwiCZXvPXnsEHxbEmUlrYv18l/6Y4BTiX7XU84hKOfGB2/nXpismaifvpUaSDd6U8DGQwy1bjV919G5
AY0EaNr26gEMAOiDFD5e9M2leghNEyS3q5Mwt7+83KP6eBJxgL4lpBJiqBcgQQX1YkhNSx4/efFFzWLhhQRVcW0b24igJrPA/zZ5X/0LktzVyG2iFNOn
t9X30wQYteYuBkY+mVS4CLHasyXKbP/FVpFUlUtwlpW1PuYoJUmlAG07hcbM5ELHvrmM+VMeTQe9jVbe4XmoL7ExH9DIGUbfY3zTuQN/oqeP8bJRLYDM
KAkuWNRl9qPXBSnoXDC1Jdp6tZ9Wt1JRjpmfl8XGHpcaoW/JXdttGWu6kPP4AuiCJHCYAayGBq8wkPY6uGhpIoGNxn71fzWjBElFg4Wc57jJ55bN12Ao
xNgH7gBjyCeZB9K6MS/ZFKqlTgJz7YdzIDLONwXjWTxOD9Yt/dbW6j89eeNHtBme9Zs2tlusSSd/kNDFt8cDazVS59ruErmv8J0T+CzoeYSQTVv38ekZ
CzxGRAeIkL5KPCN/G1gBUrVGtQ357gGzZXhqAHEbN5s4fFxRr6huhAxc4vy1wwARAQABiQG2BBgBCgAgFiEEHViJy54FZMFU4Yu1EuyVGdtDzCcFAmja
9uoCGwwACgkQEuyVGdtDzCexAgv+I5CLzkBfkJc5FED80/hOOoKG7OXQXi2/XX3o9RVkquVZG5Ltl9UVC3nA/C10zF/qb4ejH6EqiSWEr0CBkzij5uPM
pQmAZZgxgSKc1wLWgXO99bZ9W5lqHcEfpB9KGHNCVwasXikMyWrhLFsYIcBJQQe/pMGFFdOfYiGUL4nxjgu459xvv8SdSxyZlRxSuTRpAMxP9Qfg9h0f
eiEXWU9nfBSHHMEKx/IiLoeDceXhCqFx2eP+/xJLsLceIySWI6vNHx+sJJxeHtLTwiChVuet3PIZbF4ykAw3EYDGx+C5NqC0gsiEFPdD/d2WwCn5v3JR
py9oospJ4rvb6+ozXtmuqi2eKoqiEgJN12bpH8bkooFY1JE6PEu+2glKDVhV150k/bopdRaJyfnMYyh8oMmKGMTOjHRDieup7zeekhdg1el4YTRoMBFk
xcgkkA8oNSPdQGHwPoOQo0KL0lSIMsKyvnmF7k7TUdRMnOzgWNwY6rF2fWl9y5njXaYzozz8LLpvmQINBF2o3QIBEADr7LjjYbFLAJlApLJnsah98wEw
qoEQwvj8jSB3rpFyeyGgXzS56kim4LNDBtLuT3thwYg6a2RZ4ptYcn2eY3MH6SkrAb6pfaJKHaIi/4XAt9gvUedMH7Cq/PwJn0y3LSVtMuHlL+Su98NS
Sj0uK8EIVY3Qd4RWC0VEN8BiGF1E1WiwxASpEGuHNWvglqb9c4P1RR3yuwv0OEdTRIioKbs7cvTltp5vNg72+spOIvexrkPf1hP9YvKbcGgFW2i9XG6u
WaJ2sozPnrnTs2HmzpDwLDL+Woq9pmhs0wlI1OxT2LdyAYE0EvQSMozDB/3n1st8o18TS/bBRf2fSwLabDgmJunNQfMWiuPg3XSXLRTxCU+kIwhnR3R2
DlAqpKuPdZIfmLZcuHI8ogUAUZDIJ8pkf0EQBeJSU1ammSnxA65TjTx/mHiAFK62BL4efBKL74/ToTOtyFFtrbos04shZ/G1qSX50UW5E3f2NRkc46qc
c3sV+4SYvQEBnhWBYMoUpue7GHhNL1gydqXxLMqViInoOw3RbdIRK3QVgW2msdHLVvTf9hIBKo6vOHeGxnkKuNulGUUwl+B3abEbgZ3X3ep14t6EU6Zj
y7Q2x9S0DprsDFCOroSAjOXviIN4jbNKV3hvY6QuIis+/NTt3dv3hAWwJuMSLhqNcDrubrdfs8MhxwARAQABtB5LeWxlIDxrd3NhbnRpYWdvQG1haWwu
dXNmLmVkdT6JAjYEMAEKACAWIQSkfZm22w1xXUDFmiAjroqOp+JOOAUCaG70AwIdIAAKCRAjroqOp+JOOH9qEACmmGTtgw0myYSS6M0bklqGOSM82FpB
CPlhRwTNSMs5j93F9C3sz0r4EXQrbNRypRadMsN3L93dFN840nRm9iyO/3M/hZFaMsFOBNj/TEzNKof7xSzkLXp3xXFykxcqdWf6Krl5sV8/eHQ2bcA1
HYSDCe416WRP/T+JINbJSzX6t0NO/CrNQZqfmWFb1JkmqR6mZ4+YKVoLHRV9/BHP2qOBDkqypyiL7cOw7cPyqIjuZb7CAt1BFQ8AG9BIPVEFj9ETdjFS
HsFgf1UlveYavr0YANaORWq9ERcyhC5xNM6fT6Sh1P9pGgOEGyHgG1r0EIudv6zar1QrlXwom6xWjavMSgYaeQFvgvMA0uPL2T2KFgCQhvU5ug6mA2rf
tnsQmi/Im46vpqsVB7Dw3y/IdICej7qENwBPjLMn83xUVCkjUY9I5qftXOAJyDRRzebNigJAnQ7jfhF9A/S/dJXs+4au+4hKJyKuvSE8uGlDIBfTY7c8
whUU3nZEexEMQr3dFi2Iw8VCIg4FsPbVlZD8FsHDnSPkK2otZECeYmnyeVdEh/51T0AroTAs9yJJP1ebtyM9rKn2ZDV1aHQcMN9YIogzyPJlIvkoK2cg
mATARh62h+ksv8QraHOVd70gfbmO3GvZr/d/IcG/OBH+qicShHh/nPqS1lbgeI6O4jm+YdKT3rQfS3lsZSBTYW50aWFnbyA8a3lsZUBwcml2a2V5Lmlv
PokCVAQTAQoAPhYhBKR9mbbbDXFdQMWaICOuio6n4k44BQJobvPiAhsDBQkeEzgABQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJECOuio6n4k44buUQ
AOEigdjOTnSSKNxZFXYVnBz2ZR4GXYDkAY85pBjLBGEGyKsumLoKEEFxfFLJPS+jeWP+2sci1Ev0Q9BsZ9bCbkhaFo6t1WV61Hyp9KnefLA1R4LrIWyW
NawqhkxhYOYOO6mqKQ3IjTxNH2NvPwhZGpE944LYtjEZVyppwBo+VQdN5/bfz6pDBHpAFREv++HX4YYV8LXsE57cWQEVm03ig6Ug5J5U+M/OyD0pPNWR
wlp7lXNmWVwrX5J4r2fmd/WkVBBvhNEnVYwms7pRLy6YbS7cTUB4TSGq56vyjR1ny9tj79IG3SD1uQaNqFQnWuCSgfdy5Y+Libq7RqLZZqE6Am3eyEuk
GZZFjj6KNSnHkqO/y060Ej/TbTx2X/Nyp9ozD6AfDFSFyNJ09WuDBWJ3rPqxHZSFp4IgvZom3boxwC6o7mYwWZw70WZjdQXWv4h0auVjS6ye0idCjBCN
HHRo3CX1kD5vLx03sOJnEpf5DIGeO0Ze1JdhxRv3RhQbB3B7Jx5ZNVKcl7pt196UsxCNyIW+EItNeorLq7rI6345foIG3sfF/jfl/MnNa8FZrG2siGGF
73rlTMzsMN3lxBvlBcfANZqXy6M/7dnnPKd1hEA5mdJOZ7n0ijfhJRaAGe4wo3nAb7YUjbNoymQsJ4VYx+9pWFn7nInkdmvOX7Chqd6FuQINBF2o3QIB
EADiWNnkItZNmha/z53NGs6aW0GOpX6BMEtyPRBmc0cz0H5U96O5q8ySYOpYu+sjLli06FRSzDSyVOjKlqWyycLI8SnAPTUBNglTMQHy3Cvj1aiF5DJy
4sb2oPCOKyEPTFqYtLBOdR0yGXUk0HGB7XE4pe5GrhYkSk+6tev20CF3Fiyr8hVzMU0PS1Uie+NdvJMuPWaR6NdLX9G75awIdvgM3z7vGXBHSgVd/LLo
Jj4aVbb/p85b/XUv2V8GZDYoplRZ/7bdvyLBgXCy33R+TMZeb13VCsyDWWUjS/CULKNr98QBckGXNsFw0rc2mZN1PSeaarAnHmQPNjYqmv6e+CtiMwqh
I49BZB0yB4u72v0I5U5UhgOse56ZpYRRTvee6tzsmYAmXNlubiZKTbTVTWhpHHp6bCIXwZZ+3ILPM5S4Cr72WSEoRZ39o37yLRnr9VU/oi0iCa51Cjnq
lj75TrhzgK3UN9p7au7l+QrAYc9FlD70c/EGYVKGkanYO+Ez4I6e6FRKlNVnWdsr2pSNP5LJZCfQKuU8Eq8UFS/i+QTvNnXFViYK7NOcgeMgtT4y0tW2
W3f0bO34l2zGDire1LRvYssMG+oPLH287lpKGGRFX2uJKWT7XNQhnNCAG+qURNq0Aa9/qwkH9WRPoUNYcAw8s6zVRWm6l9AtVovlhotgwwARAQABiQI1
BBgBCAApBQJdqN0CCRAjroqOp+JOOAIbDAUJHhM4AAQLBwkDBRUICgIDBBYAAQIAAOIOEADiH9+Q8saUYSZxleKc9IeIFRmB9LuhmJWAh6WFWpScppaL
Ol7fH1yBgKYSwEKD/AwuAChffyLaXq2shdbItv0oYAZxRdVftC/yoT32dRvelNAwu5drJTHE5jSGS0x9rnSAK5aYUPoVEo+n5pnm9jP0Ply4Yn2HEenY
TsTis46V/0srkcLm7DbfmYNe5U1MCySuW16bEix7aWtYdEQkL1L/TRbhEIFO5AIeAQLPJHadqzi6VNPADDJ5TM5NXhn/KY6D9TftbwFeKpDjcO/KpN3j
a+lwdrvV2YMqk5qj1kE9eyF6L+zyuTszjW4WtReyPrCyMjhi59CQ+8simqn74qo+ZieK/p0Xk/pJznBFpv+IG18OCVwION8uK74ky1lqE62S1yz3e7hW
xmWB0uFnZk1JE5SFXdkijrxIJp7cIKksQHCjnvIC2iXh97OnbNpUrERzA3ZqBOmkcsEdlCLJg7cVzpSKaVMSDlCRk0XeGyi0zaq/Q6EVQD6Brg8auvCN
DT1JMHdc3hN5mbVQNJLtcELuG99vFSkE18yScC/Qf2JE7LpKlHKB13PLbEpDS41HByqrvXYVNz6YsBBjgP6HymsNuWu5O0s3JEqaj4Uf74ntzUScYV+B
ODdksovzCpo+yjTxaVIq3oOntJZQW9Gdv0YSGNzDY6GgqjcNs/IokyMIYpkCDQRn0WIrARAAsgPXekQR1WXh6sfOZqWisO13fHkyl58bn0FhxF1TRxL0
iw7IGyXp1me70Baz3WCw316FAotsalc3qDCzc4T65XaunZtvf6a1elCelVUIqCfSEPEMiy7Y0rEz5rC11L7h/dGMkVBtUvMZEWhymoBOEqRoKaeUHahe
EFNHRYukXp+bJeblKX4P+1Nzv6VBXoglhc76hSgisNsZI3FTfd7svj1DU+9Q91ERqPjiWZz3Z6pn3uYCo0HZ+FsLH4JjylP+v8pHMxYDuXuxiTBC/3ON
3nw18SmzUe3t4V7s9JxkMB5to/r/18hZ/rdNkC/fb/5Z1a28/9L6fMmwu0kHvl7862pyDBajdW1WfEbOfPPVzvEwFXohDEkyaj21nVBL1wU8hkRJRp7q
3DCz2S9g60eO2c0vqjegTSVTyUmxAPVZCYZTuaKXx58AifPfoUUrZzPZ39X7F3Uzaskn1u+KGgQjsdNQX4KzJ/VQQokWVx6d2/F/mYXzjht1z9Dkawm1
GUxr7xfkZIsLt84AGWBYYG0AVLVmJmlNiZ4QYNb8Rj9Bbu3+Os/MAZqXk1znvUMfiWSFVoDDwtU1Jao2PvA802o3PDsqXDWEBgqkVQ96X5yrXfO3pCvO
oE3D+p0exvL23Xgb4qcBCL/5Nr4hcSC2PDyRfIQ9y9PLGwkj9IAaWNZsxo0AEQEAAbQWTMOpbyBIYWYgPGxlb0BoYWYub3ZoPokCUQQTAQgAOxYhBNrt
koxyfT5hPsRmNfUHPE9Igv/8BQJn0WIrAhsDBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEPUHPE9Igv/8fp4QAIgv5DUkk2OriZeOkWRS/FJs
oTIFKMXUukKiSxUW+yQ6O6bnAUl2Axy+BCsn45YN8xpX7xaZyR9I8l/zSXJ2zXrFVVDkL9b+z49K/toMlS0FqgWTX5p4CO1IV9P2twUQMgbtKp5raxBm
wAuJaxrl2owwhkVtJ0faxnPM6vaMZR0FxlPr+uSyN5G6KGZrT9FDAca7bB5M82pd4MprmFfyFr3D67shbZrNSKzSS7I/OMd++2Sr5zdyPsdpt1hEega9
Lby8XPsnFCM/b5Il8s3K/X1IlI3XR2UgAH8BGyUN9AzAUbVnO/cIRQFYThg274z1OhtbvX8EoL3Z3sTiHLTwzbPw/8hDLMtgIxCxWRBjf3UJ/8+Nx+Nr
BOfoN0syJT7DRUmdzmCB7cEllBD2vtFEgkPM/gIBKd6FJE3iIMooccKhwmPazc3dNHqPHBdHFQnrZ/6m3INqPoa2kiQhY0asB7pqZZ4u9sX43Ha9x5oF
0XcrfMybdi0HZQPS7WKxR9aCMfCTlG3ZbALk92+QCs9OUIhGcbcst6zZ/j9kT+DKn9eGnRItClsDYrDNW9PQ/OdjzcoNQZLxEJxqpIEtJmvtcpUWXUFj
cJJ63klt9dRGTPR4VpjLgAPs2Qk2LVxjq+2Z4aeiAVScEJ6tdAPitYkyee0dJhgJ/XmqLyN3y/hTil8FuQINBGfRYisBEADmUJxGnYsux/iJBRFvSZKv
ztvZ3iytwiSiSXY1RI/aCofz+y07RplUXTXBiI8GD55fb2Q7m8xInfQsOKvelaK9hNsQ9kUhJGGdLtRNflMK+jLnf2+LrUczoSs/3+4puI1RWene8XgQ
XUfTR9/TR/iImZ9dPvqbUT3xlrG77b7hM+ObUIfgfE8WcvpXtiHAO405oAH6uez0r9lNpVDwGeXbvChItV+9R4ntn51o3N+ItSux6bXVVdoWySVgORQx
Qh2sy062L0oBDRGkvZ83C147Ub9MsFpaMo7Ls3Iy/Fs+V6UYpDhPidVDETYCWX1YCgAIkFmYJP+C1jcpz58M4E41JUoEDKfwxOK44NrKOD3CIq2HrSdK
8tI6frLob7zuLBspMwnbuY5D8yQBhKOM1ma+5EmwQQRHGom/wfay6TodiADVNaU1A7pRrD/1eBKXXZy0ZR5oGhBlr5mQK7uwEFlXduUD8Xi6p3dUhXwS
8sUQwu0LjctBKzu38MiGYC2tgYZvAJUn5yEig1jrcFfLx9b0T+8wdRm2WYOuSk2MAvoHzGCnhI5f/b+ml0bnkJt3jg+ljHtMQOukc7lYs38Cfh2y7LAw
rbGrRSmXihrWfhK5HJUV0VcvT6kZYoP9lyFyvhTvvZ4VC9b3G7w1QVQDf40mA7FZjrhttdbHdbZSvcHaQQARAQABiQI2BBgBCAAgFiEE2u2SjHJ9PmE+
xGY19Qc8T0iC//wFAmfRYisCGwwACgkQ9Qc8T0iC//ybuRAAoBSg5PTzF+YtE+Rr8C9QY2iQNqeGTkCNt6lLSK7GxaH7P3NzIK+9AXq0ZPL9wYLmb69U
CJtrEzm0Xno5b4rUVI9NEhmTxJspZvKsmQlhW2lw9LauBnnSo1Ai3+BTPKmPPjrecEtl2TgbW1I6U/3xGXaLVYUTIEX2nEn9wBPMBTGxB/9oCD+7186E
0/v93O8ccYbFktN3xg+l7z8Wmk3Dbas+8HEa9O5GvjRnffpJvwLcNU+UeYR63mUXm1VnsAVu5MfGKHhNFfMOdj3ke2wHDdk2YLqrKXNf9OSOEtslRP1X
zAiIxqXnsu+jwh/Bke0yWMzIfccOYhyXqz1hTgaWN2my6lJV5MEx9CPAX/V01fQpFgjw3mai1xHRvuvvnqRK4iC2w81iYCpChw9J1tArO6k8N5+Wxm1r
23WsSdD/P/3lUFn53ZCzPk1YpZBT5SyicCdqM9INZ8/R+ywaXuwPYRLtfBAmHL+ItGJ/HJhPDXtGA994IPn6J5vXnGwfkNV2vuhmibcLTVY+/mlWxSje
fwGIduUZCZTJEIDG8JAbb3SMmOyXXu2HXhG1cn9mfyzvhyGHykPgoReM3h4EJ5r8PTm2/sn4s9bIciuBPxNmTxGjTyysMqOL0wBi+s14gcXbrfw5fBaM
W/xaWb4iyc9lI4aS0fdKf8FudIUTmdlnz5Y=
KEYS
}

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
LOGD=/var/lib/alphapool/log    # every log of the installer (root only). Nothing is written under /var/log: see "the one rule"
LOG=$LOGD/install.log
VAR=/var/lib/alphapool          # the installer's own work area: root only (0700), see "work area" below
DL=$VAR/dl                      # the UTXO snapshot while it downloads (a re-run resumes it)
HAND=/var/lib/alphapool-handover   # root's; the node user may read it, not write: the checked snapshot file while the node loads it
TMPD=$VAR/tmp                   # scratch: one fresh directory per run
OLD_DL=/var/tmp/alphapool       # where installers before 2026-10-07.2 kept downloads; never used any more
SETS=$LIB/sets                  # the software sets: one directory per installed combination of programs
CUR=$LIB/current                # link to the active set
JOURNAL=$ETC/upgrade.journal    # there while an upgrade is in flight: previous set, new set, step
UJ=$ETC/validated-start.journal # there while a validated start is not finished: which UTXO snapshot it uses
NETWORK_PAUSE=$ETC/network-paused # durable intent: this installer paused a node that had networking enabled
case "$NODE_CHAIN" in main) CDIR=$DD;; *) CDIR=$DD/$NODE_CHAIN;; esac   # where the node keeps blocks/ and chainstate/
RUN=/run/alphapool
UNITS=/etc/systemd/system
INSTALL_UNIT=alphapool-node-install
LOCK=/run/alphapool-node-install.lock
TOTAL_STEPS=9

# ==== test mode: AP_DRY_RUN=1 (refused outside a throwaway container) =================================================
# Skips apt, downloads (AP_DRY_FIXTURES=/dir supplies them by file name), systemd, ufw, iptables, swap and network
# probes; runs every validation and writes every file. Planned commands go to /var/lib/alphapool/log/dry-run.plan.
DRY=${AP_DRY_RUN:-0}
PLAN=$LOGD/dry-run.plan
is_dry(){ [ "$DRY" = 1 ]; }
in_container(){ [ -e /.dockerenv ] || [ -e /run/.containerenv ]; }

# ==== output ===========================================================================================================
WARNINGS=()
PHASE=preflight
TXN_OPEN=0                      # 1 while an upgrade has stopped services and not yet finished or rolled back
FAST_OPEN=0                     # 1 while a validated start is being made
NETWORK_RECOVERY=0              # networking recovery may have changed the running node before preflight finishes
english_console(){
  [ "${TERM:-}" = linux ] && return 0
  case "$(tty 2>/dev/null)" in /dev/tty1|/dev/ttyS0) return 0;; esac
  local output_pid=$BASHPID
  case "$(readlink "/proc/$output_pid/fd/1" 2>/dev/null)" in /dev/tty1|/dev/ttyS0) return 0;; esac
  return 1
}
say(){ printf '%s\n' "$*"; }
say_zh(){ english_console || say "$*"; return 0; }
# The worker log keeps both languages for SSH. Linux console fonts cannot draw Chinese.
terminal_output(){ if english_console; then LC_ALL=C sed -u '/[^[:print:][:space:]]/d'; else cat; fi; }
say_t(){ printf '%s  (%s)\n' "$*" "$(date -u +%H:%M:%SZ)"; }   # events with a time stamp: durations are readable
warn(){ printf 'WARNING: %s\n' "$*"; WARNINGS+=("$*"); }
# die CODE MESSAGE: a plain-language error with a code the AlphaPool dashboard explains (README "Error codes").
die(){
  local code=$1; shift
  printf '\nERROR [%s]: %s\n' "$code" "$*"
  if [ "$PHASE" = preflight ]; then
    if [ "$code" = AP-415 ]; then say "Networking recovery did not finish. Any pending recovery marker and validated-start journal were kept."
    elif [ "$NETWORK_RECOVERY" = 1 ]; then say "Earlier networking recovery ran before this check. Fix the problem above and run the same command again."
    else say "Nothing was changed on this server. Fix the problem above and run the same command again."; fi
    [ "$MODE" = install ] && issue_set "install NOT started [$code]: $* - fix it, then run the install command again"
  elif [ "$PHASE" = upgrade ]; then
    [ "$TXN_OPEN" = 1 ] && txn_rollback           # never leave with services stopped or a half-made switch
    say "The upgrade did not go through. Your node runs the software it ran before, unless the message above says otherwise."
    printf 'upgrade-failed %s %s\n' "$code" "$(date -u +%FT%TZ)" > "$ETC/last-result" 2>/dev/null
    rm -f "$ETC/upgrade-request" 2>/dev/null
  elif [ "$FAST_OPEN" = 1 ]; then
    fast_abort                                    # a failed validated start must not become a days-long sync by itself
    say "The install stopped at step ${STEP_N:-?}/$TOTAL_STEPS (${STEP_NAME:-}): the validated start did not go through."
    say "The node was stopped, so that it does not start syncing the whole chain from the network by itself (days)."
    say "Fix the problem above and run the same command again: it continues where it stopped (downloads resume)."
    say "To let the node sync from the network instead, run it again with --sync network."
    rm -f "$ETC/install-in-progress" 2>/dev/null
    printf 'failed %s %s\n' "$code" "$(date -u +%FT%TZ)" > "$ETC/last-result" 2>/dev/null
    issue_set "install FAILED [$code] - log in and run: alphapool-node status"
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
  [ "$STEP_N" -lt "$TOTAL_STEPS" ] && issue_set --no-reload "installing (step $STEP_N/$TOTAL_STEPS: $STEP_NAME) - log in and run: alphapool-node status"
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
  local reload=1
  if [ "${1:-}" = --no-reload ]; then reload=0; shift; fi
  [ -d /etc/issue.d ] || mkdir -p /etc/issue.d 2>/dev/null || return 0
  printf 'AlphaPool node: %s\n\n' "${*//\\/}" > /etc/issue.d/alphapool.issue 2>/dev/null || return 0
  [ "$reload" = 0 ] || is_dry || timeout 5 agetty --reload >/dev/null 2>&1
  return 0
}
run(){ if is_dry; then printf 'DRY: %s\n' "$*" >> "$PLAN"; return 0; fi; "$@"; }   # systemctl/ufw/iptables/swap
run_q(){ if is_dry; then run "$@"; return; fi; local o; o=$("$@" 2>&1) && return 0; printf '%s\n' "$o"; return 1; }   # quiet unless it fails
# Test hook, inert on a normal server: /etc/alphapool/test-fault (a file only root can create) names steps of an upgrade
# to break, one per line. "fail:<step>" makes that step fail once, "kill:<step>" kills the installer there the way a
# crash would (kill -9), "reboot:<step>" resets the machine there like a power cut. Only the tests use it.
fault(){   # STEP: 0 = this step must fail now
  local f=$ETC/test-fault k
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %u -- "$f" 2>/dev/null)" = 0 ] || return 1
  for k in kill reboot fail; do
    grep -qxF "$k:$1" "$f" 2>/dev/null || continue
    sed -i "0,/^$k:$1\$/{//d}" "$f"; sync "$f" "$ETC" 2>/dev/null       # each line fires once, also across a reset
    case "$k" in
      kill)   kill -KILL $$ "$BASHPID"; sleep 5;;
      reboot) echo b > /proc/sysrq-trigger; sleep 30;;
      fail)   say "  (test: the step $1 fails here)"; return 0;;
    esac
  done
  return 1
}

# ==== the installer's own work area ====================================================================================
# Downloads, archives while they are checked and files while they are staged live in /var/lib/alphapool, which only
# root can enter (0700). The installer makes it. A path that already exists is never trusted as it is found: it must
# be a real directory (not a link), belong to root, and be writable by root alone; otherwise the run stops (AP-211).
# Nothing is written under /tmp or /var/tmp, where another account could have made the name first.
priv_dir(){   # DIR: 0 = DIR is a root-only directory now (made 0700, or it passed the checks and was set to 0700)
  local d=$1 o
  mkdir -m 0700 -- "$d" 2>/dev/null && return 0          # mkdir never follows a link and fails on any existing name
  [ ! -L "$d" ] && [ -d "$d" ] || return 1
  o=$(stat -c '%u %a' -- "$d") || return 1
  [ "${o%% *}" = 0 ] || return 1
  (( (8#${o##* } & 8#022) == 0 )) || return 1
  chmod 0700 -- "$d"
}
WORK=""
work_dir(){   # sets WORK: this run's private scratch directory (removed when the run ends)
  [ -n "$WORK" ] && [ -d "$WORK" ] && return 0
  local d
  for d in "$VAR" "$LOGD" "$DL" "$TMPD"; do
    priv_dir "$d" || die AP-211 "$d is there already, but not as a directory of root's alone (it is a link, belongs to another user, or others may write to it). The installer keeps its downloads there and will not use it like this. Look at it, remove it (rm -rf $d), then run again."
  done
  rm -rf "$TMPD"/run.* 2>/dev/null                       # left by a run that was killed (one installer runs at a time)
  WORK=$(mktemp -d "$TMPD/run.XXXXXXXX") || die AP-211 "no work directory could be made in $TMPD (is the disk full?)"
  # What an installer before 2026-10-07.2 left in /var/tmp/alphapool is not used. If that directory is root's alone
  # it is removed (it can hold gigabytes of a partial snapshot); otherwise it is left exactly as it is.
  if [ -d "$OLD_DL" ] && [ ! -L "$OLD_DL" ] && [ "$(stat -c %u -- "$OLD_DL")" = 0 ] && (( (8#$(stat -c %a -- "$OLD_DL") & 8#022) == 0 )); then
    rm -rf -- "$OLD_DL"
  fi
}
# new_file PATH: an empty file made with O_EXCL, so that writing it can never go through a link; whatever had that
# name is removed first.
new_file(){ rm -f -- "$1" 2>/dev/null; ( set -o noclobber; : > "$1" ) 2>/dev/null && [ -f "$1" ] && [ ! -L "$1" ]; }
# plain_own PATH: a download is continued only if it is a plain file of root's with one name (no link of either kind)
plain_own(){ [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u %h' -- "$1" 2>/dev/null)" = "0 1" ]; }
# ==== the one rule about paths that another account can rename =========================================================
# Root never opens, reads, writes, moves, removes, or changes the owner or mode of anything by a path that leads through
# a directory in which another account can rename entries. On this server those are:
#   the node user's home, /home/alphapool, with the data folder (.bitcoin) and the gateway folder in it;
#   /var/log, where the system's log account can write.
# A link put into such a directory at the right moment would send root's file operation to any file on the server.
# So:  whatever lives in the node user's folders is handled by a process of THAT user (as_u, has_u, sha_u, conf_u,
#      cli): it can reach nothing its own account could not reach anyway;
#      whatever root owns lives in directories of root's: the programs in /usr/local/lib/alphapool/sets, downloads
#      and logs in /var/lib/alphapool, the snapshot file the node must read in /var/lib/alphapool-handover.
# tests/test_install.py (RootPathTests) reads this file and fails when a line names such a path outside these helpers.
as_u(){ ( cd / 2>/dev/null; exec env HOME="$HOME_U" USER="$U" LOGNAME="$U" setpriv --reuid="$U" --regid="$U" --init-groups -- "$@" ); }   # run it as the node user
has_u(){ as_u test "$@" 2>/dev/null; }                                              # test -e / -x / -f ... as the node user
sha_u(){ as_u sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }                          # sha256 of a file in the node user's folders
conf_u(){ as_u cat "$BTC_CONF" 2>/dev/null | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | head -1 | tr -d '\r'; }   # a bitcoin.conf value (first wins, like bitcoind)
# A program YOU name (--gateway-file, --knots-dir) is copied into root's scratch directory before anything else is done
# with it. If it lies in the node user's home, a process of that user reads it: a link there that leads to a file only
# root may read is then simply not readable. Anywhere else root reads the path you gave.
in_node_home(){   # PATH: it lies in the node user's home (as it is written, or where its links lead)
  local p h
  p=$(readlink -m -- "$1" 2>/dev/null) || p=$1
  h=$(readlink -m -- "$HOME_U" 2>/dev/null) || h=$HOME_U
  case "$1/" in "$HOME_U"/*) return 0;; esac
  case "$p/" in "$h"/*|"$HOME_U"/*) return 0;; esac
  return 1
}
src_copy(){   # FILE DEST: DEST is a new file in a directory of root's
  if in_node_home "$1"; then as_u cat "$1" > "$2" 2>/dev/null && [ -s "$2" ] && chmod 0755 "$2"
  else install -m 0755 "$1" "$2"; fi
}
# log_open: the log directory is made (root only) or checked like every directory of the work area; the log is opened
# there. Every entry point calls it: install, upgrade, the background worker, uninstall.
log_open(){
  priv_dir "$VAR" && priv_dir "$LOGD" || return 1
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then plain_own "$LOG"; return; fi      # an existing name is never opened unless it is root's own plain file
  ( umask 077; set -o noclobber; : > "$LOG" ) 2>/dev/null
}
shared_dir(){   # DIR: a directory of root's that the node user may read and not write (root:<node user> 0750), made or checked
  local d=$1 o
  if ! mkdir -m 0750 -- "$d" 2>/dev/null; then
    [ ! -L "$d" ] && [ -d "$d" ] || return 1
    o=$(stat -c '%u %a' -- "$d") || return 1
    [ "${o%% *}" = 0 ] && (( (8#${o##* } & 8#022) == 0 )) || return 1
  fi
  chgrp -- "$U" "$d" && chmod 0750 -- "$d"
}
on_exit(){   # every way out: an open upgrade is rolled back, the scratch directory goes
  if [ "$TXN_OPEN" = 1 ]; then      # cut off by a signal in the middle (AP-516): the log is in root's directory, so it can be opened again
    exec >>"$LOG" 2>&1
    say "  the upgrade was cut short: putting the previous programs back"
    txn_rollback
    printf 'upgrade-failed AP-516 %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result" 2>/dev/null
    rm -f "$ETC/upgrade-request" 2>/dev/null
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
# One installer at a time. Every command that changes anything takes this lock first and keeps it while it makes its
# changes; the background worker then takes it over. A second command started meanwhile changes nothing and shows
# the progress of the first.
unit_state(){ systemctl is-active "$1" 2>/dev/null | head -n 1; }
take_lock(){
  install -d -m 0755 "$RUN" 2>/dev/null
  exec 9>"$LOCK" || return 1
  flock -n 9 || return 1
  is_dry && return 0
  case "$(unit_state "$INSTALL_UNIT.service")" in active|activating|deactivating) return 1;; esac
  return 0
}
hold_lock(){ { : >&9; } 2>/dev/null || exec 9>"$LOCK"; flock -n 9; }      # this process has the lock (it takes it if nobody has)
busy(){
  local off
  exec 9>&-                                      # this command only watches from here on: it must not hold the lock the worker waits for
  say ""
  say "An AlphaPool node install or upgrade is already running on this server. This command changed nothing."
  say "  now: $(cat "$RUN/install-status" 2>/dev/null || echo starting)"
  if is_dry || [ "$FOREGROUND" = 1 ] || [ "$FOLLOW" = 0 ]; then say "Progress: alphapool-node status   Log: $LOG"; drain; exit 1; fi
  case "$(unit_state "$INSTALL_UNIT.service")" in active|activating) ;; *) say "Progress: alphapool-node status   Log: $LOG"; drain; exit 1;; esac
  say "Showing its progress (Ctrl-C stops watching, not the run):"
  sleep 0.5; off=$(stat -c %s "$LOG")
  follow "$off"
}
# The log goes through a process-substituted tee; drain lets it flush the last lines before the script exits.
TEE_PID=""
start_tee(){ exec 3>&1 4>&2; exec > >(tee -a "$LOG") 2>&1; TEE_PID=$!; }
# A prompt goes directly to /dev/tty. Close the log pipe and wait for its reader first,
# so every summary line has reached the terminal before that prompt is written.
flush_tee(){
  [ -n "$TEE_PID" ] || return 0
  local pid=$TEE_PID
  exec 1>&3 2>&4
  TEE_PID=""
  wait "$pid"
}
drain(){ [ -n "$TEE_PID" ] || return 0; exec >&- 2>&-; local i; for i in $(seq 1 30); do kill -0 "$TEE_PID" 2>/dev/null || return 0; sleep 0.1; done; }

# ==== small helpers ====================================================================================================
sha_of(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
gw_src(){ [ -n "$GW_GIT_URL" ] && [ -n "$GW_GIT_COMMIT" ] && printf '%s %s' "$GW_GIT_URL" "$GW_GIT_COMMIT"; return 0; }   # "<repository> <commit>", or nothing
gw_git_hint(){   # one more line for --help when the pinned build has a public source
  [ -n "$(gw_src)" ] || return 0
  printf "\n                                           (the source of AlphaPool's build: --gateway-git %s\n                                           --gateway-commit %s)" "$GW_GIT_URL" "$GW_GIT_COMMIT"
}
sha_ok(){ [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
url_ok(){   # https only. (Test mode also takes a server inside the same throwaway container.)
  [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=,@-]*$ ]] && return 0
  is_dry && [[ $1 =~ ^http://127\.0\.0\.1:[0-9]{1,5}/[A-Za-z0-9._~/%+=,@-]*$ ]]
}
rand_hex(){ head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }
gb(){ awk -v b="$1" 'BEGIN{printf "%.1f", b/1e9}'; }
sep(){ printf '%s' "$1" | sed -E ':a;s/^([0-9]+)([0-9]{3})/\1,\2/;ta'; }      # 910000 -> 910,000
hex_rev(){ local h=$1 o="" i; for (( i=${#h}-2; i>=0; i-=2 )); do o+=${h:i:2}; done; printf '%s' "$o"; }   # byte order reversed
dur(){ local s=$1; if [ "$s" -lt 5400 ]; then printf '%d min' $(( s / 60 )); else printf '%d h %02d min' $(( s / 3600 )) $(( s % 3600 / 60 )); fi; }
eta_text(){   # SECONDS -> "about 3 h 20 min" (rounded: it is an estimate)
  local s=$1
  if [ "$s" -lt 300 ]; then printf 'under 5 min'
  elif [ "$s" -lt 5400 ]; then printf 'about %d min' $(( (s + 150) / 300 * 5 ))
  else printf 'about %d h %02d min' $(( s / 3600 )) $(( s % 3600 / 600 * 10 )); fi
}
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
  l=$(mktemp ${WORK:+-p "$WORK"}) && n=$(mktemp ${WORK:+-p "$WORK"}) || return 1
  if ! tar -tvf "$1" > "$l" 2>/dev/null || ! tar -tf "$1" > "$n" 2>/dev/null; then rm -f "$l" "$n"; return 1; fi
  bad=$(( $(awk '{print substr($1,1,1)}' "$l" | grep -cv '^[-d]$') + $(grep -cE '(^/|(^|/)\.\.(/|$))' "$n") ))
  rm -f "$l" "$n"
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
usage(){
  cat <<USAGE
AlphaPool node installer: Bitcoin Knots + a DATUM gateway on your own server (Ubuntu 22.04 or 24.04 LTS, x64).

  sudo bash ap-node.sh --address <payout address> [options]

Your settings
  --address ADDR          payout address (1..., 3... or bc1...). Required the first time.
  --tag "NAME"            block name written into blocks your node finds (1-16 characters). Optional.
  --stratum-port N        port your rigs connect to (default 23334)
  --alias-ports "P Q"     extra ports that lead to the same stratum port (for example "3333 7777"); "none" removes them
  --public-host HOST      name or IP your rigs use, shown in the summary (default: this server's public IPv4)

Status heartbeat to your AlphaPool dashboard (OFF unless you give a node id and token; status only, never secrets)
  --node-id UUID          your node id from the dashboard ("My node")
  --token HEX | --token - read the 64-hex token from the command line, or from stdin / a hidden prompt with "-"
  --token-file PATH       read it from a file only root can read (chmod 600)
  --no-heartbeat          turn the heartbeat off

Software (default: AlphaPool's tested Bitcoin Knots $KNOTS_VER and DATUM gateway release $GW_VER)
  --gateway alphapool                      AlphaPool's gateway build
  --gateway-file PATH                      a gateway binary you built or downloaded
  --gateway-url URL --gateway-sha256 HEX   a gateway release (archive or binary) and its sha256
  --gateway-git URL --gateway-commit HEX   build a DATUM gateway from source at that commit$(gw_git_hint)
  --knots alphapool                        AlphaPool's Knots pin
  --knots-url URL [--knots-sha256 HEX]     another Bitcoin Knots release archive. Without --knots-sha256 its builder
                                           signatures must be valid (SHA256SUMS.asc next to it), or nothing is
                                           installed. With --knots-sha256 YOUR sha256 decides: missing or invalid
                                           signatures are then a warning, not a stop
  --knots-dir DIR                          bitcoind + bitcoin-cli you built (DIR or DIR/bin)

USAGE
  cat <<USAGE
How the node gets its chain
  (default)               the validated start: your node loads the UTXO snapshot whose block and content hash are
                          compiled into its Bitcoin Knots, then validates every block since then by itself. With
                          the default start mode that takes $M_ABOUT on a small server; you see the blocks
                          left and the time left. The history before the snapshot is checked in the background.
                          Keep mining where you are until the installer, or alphapool-node status, says READY
  --start NAME            the start mode: the Bitcoin Knots build the node runs and the snapshot it starts from.
                          This installer has:
$(mode_help)
  --sync network          sync everything from the Bitcoin network yourself: takes days on a small server
USAGE
  cat <<'USAGE'
  --utxo-height N         the validated start from another UTXO snapshot of this installer's list (by block height)
  --utxo-url URL --utxo-sha256 HEX --utxo-bytes N --utxo-height N
                          the validated start from a UTXO snapshot file you name. Your Bitcoin Knots build must have
                          that block compiled in; the installer asks it before it downloads the file
  --no-torrent            download the snapshot over https only (default: BitTorrent first, when the installer pins
                          the file's info hash; https is the fallback)
  --no-seed               do not seed the snapshot to other installing nodes after the download (default: up to 2 h)

Behaviour
  --yes                   do not ask questions
  --no-follow             start the install in the background and return (cloud-init uses this)
  --foreground            run in this terminal instead of a background service
  --ssh-port N            your SSH port, if it is not detected (it always stays open)
  --firewall off          leave the firewall alone
  --no-port-check         skip the outside check of the stratum port (it asks ifconfig.co to connect back)
  --repair                run again with the saved settings
  --upgrade               move Bitcoin Knots and the gateway to the versions this installer pins, in place: chain data,
                          settings, firewall and your edits stay. All programs change together in one step; if the
                          new node or gateway does not come up, the previous ones are put back and started. An
                          upgrade that is cut short (a kill, a power cut) is finished, or put back, when the server
                          starts again or when you run this again. Software you chose yourself (bitcoind,
                          bitcoin-cli or the gateway) is left alone unless you add --knots alphapool and/or
                          --gateway alphapool
  --uninstall [--keep-chain]   remove everything this installer added
  --check                 only validate --address/--tag/--node-id and exit
  --print-cloud-init [--format script|cloud-config] [--installer-url URL]
                          print first-boot user data for your provider that downloads this exact installer,
                          checks its sha256 and runs it with your settings and with every option given here
                          (default format: a #!/bin/bash script, which cloud-init runs once at first boot without
                          touching the provider's own settings)
  --version, --help

Afterwards: alphapool-node status | logs | restart | heartbeat off | switch ... | upgrade | uninstall
USAGE
}

mode_help(){   # the start modes of this installer, for --help (in a subshell: the caller's mode stays loaded)
  local n
  for n in $(mode_names); do
    ( mode_load "$n" || exit 0
      printf '                            %s%s: %s\n' "$M_NAME" "$([ "$M_NAME" = "$START_DEFAULT" ] && echo ' (the default)')" "$M_LABEL"
      { printf 'Bitcoin Knots %s; the snapshot of block %s; then %s of validating on a small server. ' "$M_VER" "$(sep "$M_HEIGHT")" "$M_ABOUT"
        [ "$M_VERIFY" = builders ] || printf 'NOT signed by the Bitcoin Knots release builders: pinned by its sha256 in this installer. '
        printf '%s\n' "$M_TRUST"; } | fold -s -w 88 | sed 's/ *$//; s/^/                              /'
      [ -z "$M_TRUST_ZH" ] || english_console || printf '                              %s\n' "$M_TRUST_ZH" )
  done
}
A_ADDRESS=""; A_TAG=""; A_TAG_SET=0; A_NODE_ID=""; A_TOKEN=""; A_TOKEN_FILE=""; A_NO_HB=0
A_STRATUM=""; A_ALIAS=""; A_ALIAS_SET=0; A_PUBLIC=""; A_SYNC=""; A_SNAP_MIRROR=""; A_START=""
A_UTXO_URL=""; A_UTXO_SHA=""; A_UTXO_BYTES=""; A_UTXO_HEIGHT=""; A_NO_TORRENT=0; A_NO_SEED=0
A_GW=""; A_GW_FILE=""; A_GW_URL=""; A_GW_SHA=""; A_GW_GIT=""; A_GW_COMMIT=""
A_KN=""; A_KN_URL=""; A_KN_SHA=""; A_KN_DIR=""
A_SSH_PORTS=""; A_FIREWALL=""; A_PORTCHECK=""; YES=0; FOLLOW=1; FOREGROUND=0; KEEP_CHAIN=0; RESUMED=0
MODE=install; CI_FORMAT=script; CI_URL=""; WORKER_KIND=install
parse_args(){
  local o v
  while [ $# -gt 0 ]; do
    o=$1; v=""
    case "$o" in --*=*) v=${o#*=}; o=${o%%=*};; esac
    case "$o" in
      --address|--tag|--node-id|--token|--token-file|--stratum-port|--alias-ports|--public-host|--sync|--snapshot-url|--start|\
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
      --snapshot-url) A_SNAP_MIRROR=$v;;   --start) A_START=$v;;
      --no-torrent) A_NO_TORRENT=1;;       --no-seed) A_NO_SEED=1;;
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
      --upgrade) MODE=upgrade;;            --pins) MODE=pins;;
      --worker-upgrade) MODE=worker; WORKER_KIND=upgrade;;
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
ADDRESS=""; TAG=""; STRATUM_PORT=23334; ALIAS_PORTS=""; PUBLIC_HOST=""; SYNC_MODE=assumeutxo
UTXO_URL=""; UTXO_SHA256=""; UTXO_BYTES=""; UTXO_HEIGHT=""     # a UTXO snapshot of your own (--utxo-*); empty = the installer's table
UTXO_TORRENT=on; UTXO_SEED=on                                   # the snapshot over BitTorrent first; seed it afterwards
SAVED_SYNC=""                                                  # what node.conf said before this run
FIREWALL=on; PORT_CHECK=on; HEARTBEAT=off; NODE_ID=""; TOKEN=""
load_settings(){
  local v
  [ -r "$CONF" ] || return 0
  v=$(kv_get "$CONF" ADDRESS) && ADDRESS=$v
  v=$(kv_get "$CONF" TAG) && TAG=$v
  v=$(kv_get "$CONF" STRATUM_PORT) && STRATUM_PORT=$v
  v=$(kv_get "$CONF" ALIAS_PORTS) && ALIAS_PORTS=$v
  v=$(kv_get "$CONF" PUBLIC_HOST) && PUBLIC_HOST=$v
  v=$(kv_get "$CONF" SYNC_MODE) && { SYNC_MODE=$v; SAVED_SYNC=$v; }
  if v=$(kv_get "$CONF" START_MODE) && [ -n "$v" ]; then START_MODE=$v; else START_MODE=$START_LEGACY; fi      # a node from before modes existed
  v=$(kv_get "$CONF" FIREWALL) && FIREWALL=$v
  v=$(kv_get "$CONF" PORT_CHECK) && PORT_CHECK=$v
  v=$(kv_get "$CONF" HEARTBEAT) && HEARTBEAT=$v
  v=$(kv_get "$CONF" NODE_ID) && NODE_ID=$v
  v=$(kv_get "$CONF" UTXO_URL) && UTXO_URL=$v
  v=$(kv_get "$CONF" UTXO_TORRENT) && UTXO_TORRENT=$v
  v=$(kv_get "$CONF" UTXO_SEED) && UTXO_SEED=$v
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
  [ -n "$A_START" ] && START_MODE=$A_START
  [ -n "$A_FIREWALL" ] && FIREWALL=$A_FIREWALL
  [ -n "$A_PORTCHECK" ] && PORT_CHECK=$A_PORTCHECK
  [ -n "$A_UTXO_URL" ] && UTXO_URL=$A_UTXO_URL
  [ "$A_NO_TORRENT" = 1 ] && UTXO_TORRENT=off
  [ "$A_NO_SEED" = 1 ] && UTXO_SEED=off
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
  case "$FIREWALL" in on|off) ;; *) die AP-106 "--firewall must be on or off";; esac
  case "$PORT_CHECK" in on|off) ;; *) PORT_CHECK=on;; esac
  if [ "$HEARTBEAT" = on ]; then
    uuid_ok "$NODE_ID" || die AP-110 "--node-id must be the node id from your AlphaPool dashboard (a uuid like 0f8c...-....)"
    if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then TOKEN=$(head -c 200 "$TOKEN_FILE" | tr -d '[:space:]'); fi
    token_ok "$TOKEN" || die AP-111 "the heartbeat token must be the 64-character token from your dashboard (--token, --token - or --token-file)"
  fi
  validate_choices
}
validate_choices(){   # how the node gets its chain, and which software: the same rules for an install and for cloud-init user data
  mode_apply || die AP-105 "'$START_MODE' is not a start mode of this installer. It has: $(mode_names). Choose one with --start."
  # AlphaPool's pre-synced chain copy is gone: a node validates the chain itself. A node that was installed with it keeps its chain.
  [ "$A_SYNC" != snapshot ] || die AP-105 "--sync snapshot (AlphaPool's pre-synced chain copy) is not offered any more: a node validates its chain itself. Leave --sync out for the validated start, or use --sync network."
  [ -z "$A_SNAP_MIRROR" ] || die AP-105 "--snapshot-url belonged to the pre-synced chain copy, which is not offered any more"
  [ "$SYNC_MODE" != snapshot ] || SYNC_MODE=assumeutxo
  case "$SYNC_MODE" in network|assumeutxo) ;; *) die AP-105 "--sync must be assumeutxo (the validated start, the default) or network";; esac
  # a UTXO snapshot of your own: all four values. Or the height alone, to take that line of the installer's table.
  if [ -n "$UTXO_URL$UTXO_SHA256$UTXO_BYTES" ]; then
    { url_ok "$UTXO_URL" && sha_ok "$UTXO_SHA256" && [[ $UTXO_BYTES =~ ^[1-9][0-9]{0,14}$ ]] && [[ $UTXO_HEIGHT =~ ^[1-9][0-9]{0,8}$ ]]; } \
      || die AP-105 "a UTXO snapshot of your own needs all four: --utxo-url (https), --utxo-sha256, --utxo-bytes and --utxo-height"
  elif [ -n "$UTXO_HEIGHT" ]; then
    [[ $UTXO_HEIGHT =~ ^[1-9][0-9]{0,8}$ ]] || die AP-105 "--utxo-height must be a block height"
  fi
  case "$UTXO_TORRENT" in on|off) ;; *) UTXO_TORRENT=on;; esac
  case "$UTXO_SEED" in on|off) ;; *) UTXO_SEED=on;; esac
  [ -z "$A_UTXO_URL$A_UTXO_SHA$A_UTXO_BYTES$A_UTXO_HEIGHT" ] || [ "$SYNC_MODE" = assumeutxo ] || die AP-105 "the --utxo-* options go with --sync assumeutxo (the validated start)"
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
  if [ -n "$A_KN_URL" ]; then
    url_ok "$A_KN_URL" && { [ -z "$A_KN_SHA" ] || sha_ok "$A_KN_SHA"; } || die AP-121 "--knots-url needs an https URL; --knots-sha256, if you give it, is 64 hex characters"
  fi
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
fs_id(){ local p=$1; while [ ! -e "$p" ]; do p=$(dirname "$p"); done; stat -c %d "$p"; }
# space_for DL_BYTES HOME_BYTES: room for DL_BYTES in the work area (/var/lib/alphapool) and HOME_BYTES in the node
# user's home. On one filesystem (the usual VPS) both are needed together. Sets SP_AVAIL, SP_NEED, SP_WHERE.
SP_AVAIL=0; SP_NEED=0; SP_WHERE=""
space_for(){
  local a
  SP_WHERE=""; SP_AVAIL=$(free_bytes "$HOME_U"); SP_NEED=$2
  if [ "$(fs_id "$VAR")" = "$(fs_id "$HOME_U")" ]; then SP_NEED=$(( $1 + $2 )); [ "$SP_AVAIL" -ge "$SP_NEED" ]; return; fi
  [ "$SP_AVAIL" -ge "$SP_NEED" ] || return 1
  a=$(free_bytes "$VAR"); [ "$a" -ge "$1" ] && return 0
  SP_AVAIL=$a; SP_NEED=$1; SP_WHERE=" where downloads go ($VAR)"; return 1
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
  local big="" big_bytes=0 big_what=""
  if [ "$CHAIN_PRESENT" = 0 ] && [ "$SYNC_MODE" = assumeutxo ]; then big=$UX_URL; big_bytes=$UX_BYTES; big_what="UTXO snapshot"; fi
  for host in "$POOL_HOST" "${KNOTS_URL#https://}" "${PIN_GW_URL#https://}" "${big#https://}"; do
    [ -n "$host" ] || continue
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
  if [ -n "$big" ]; then
    local big_port; big_port=$(printf '%s' "$big" | sed -nE 's#^https://[^/:]+:([0-9]+)/.*#\1#p'); big_port=${big_port:-443}
    probe_url "$big"; st=$?
    # Refused while the same server just answered for the gateway: it is shedding load, so the download is busy.
    [ $st -eq 3 ] && [ -n "$gw_host_ok" ] && [ "$gw_host_ok" = "$(host_port "$big")" ] && st=2
    if [ $st -eq 3 ]; then
      local i; for i in 1 2; do sleep "$(is_dry && echo 0 || echo 10)"; probe_url "$big"; st=$?; [ $st -eq 3 ] || break; done
    fi
    case $st in
      0) if [ -n "$HEAD_LEN" ] && [ "$HEAD_LEN" != "$big_bytes" ]; then
           die AP-304 "the $big_what on the download server is not the one this installer pins (size $HEAD_LEN, expected $big_bytes). AlphaPool may be publishing a new one: get the current command from your dashboard."
         fi;;
      2) say "  the download server is busy right now (all download slots are in use): the install will wait for a free slot";;
      4) die AP-304 "the $big_what this installer pins is not on the download server. AlphaPool may be publishing a new one: get the current command from your dashboard.";;
      *) die AP-302 "this server cannot download the $big_what from ${big#https://} (${PROBE_ERR:-no answer}). Allow outgoing TCP $big_port in your provider's firewall.";;
    esac
  fi
  if net_fail prime || { ! is_dry && ! timeout 12 bash -c "exec 9<>/dev/tcp/$POOL_HOST/$POOL_PORT" 2>/dev/null; }; then
    die AP-303 "this server cannot reach AlphaPool ($POOL_HOST, TCP port $POOL_PORT). Allow outgoing TCP $POOL_PORT in your provider's firewall."
  fi
  say "  network: AlphaPool and the download servers are reachable"
}
CHAIN_PRESENT=0
# chain_there: the node has chain data. What an installer before 2026-10-08.1 left of an unpack that was cut short
# (its marker is still there) does not count: step 5 removes it.
chain_there(){
  id -u "$U" >/dev/null 2>&1 || return 1
  has_u -e "$DD/.alphapool-restore-in-progress" && return 1
  has_u -e "$CDIR/blocks" || has_u -e "$CDIR/chainstate" || has_u -e "$CDIR/chainstate_snapshot"
}
chain_present(){   # sets CHAIN_PRESENT: 1 = this server has chain data that is kept as it is
  CHAIN_PRESENT=0
  chain_there && CHAIN_PRESENT=1
  uj_pending && [ "$SYNC_MODE" = assumeutxo ] && CHAIN_PRESENT=0      # a validated start that is not finished goes on
  return 0
}
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
  chain_present
  local need_dl=0 need_home avail have=0
  if [ "$CHAIN_PRESENT" = 1 ]; then need_home=$(( 4 * 1000**3 ))
  else case "$SYNC_MODE" in
    assumeutxo) utxo_early
                need_dl=$(( 12 * 1000**3 ))                        # until the snapshot is known (a build of your own)
                if [ -n "$UX_URL" ]; then
                  plain_own "$DL/$UX_FILE" && have=$(on_disk "$DL/$UX_FILE")
                  need_dl=$(( UX_BYTES - have )); [ "$need_dl" -ge 0 ] || need_dl=0
                fi
                need_home=$(( 30 * 1000**3 ));;                    # the chain state the snapshot becomes, the blocks, the history check
    network)    need_home=$(( 30 * 1000**3 ));;
  esac; fi
  space_for "$need_dl" "$need_home" || die AP-206 "this server has $(gb "$SP_AVAIL") GB of free disk$SP_WHERE; the node needs $(gb "$SP_NEED") GB now (the UTXO snapshot file, the chain state it becomes, and room for blocks). Pick a plan with 80 GB or more."
  avail=$SP_AVAIL
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
}
show_plan(){
  say ""
  say "This installs an AlphaPool node on this server:"
  say "  payout address : $ADDRESS"
  say "  block name     : ${TAG:-(none)}"
  say "  rigs connect to: port $STRATUM_PORT${ALIAS_PORTS:+ (also $ALIAS_PORTS)}"
  case "$KNOTS_CHOICE" in alphapool) say "  node software  : Bitcoin Knots $KNOTS_VER (AlphaPool's tested pin): $M_LABEL"
      [ "$KNOTS_VERIFY" = builders ] || say "                   NOT signed by the Bitcoin Knots release builders: this build is pinned by its sha256 in this installer"
      say "                   $M_TRUST"
      [ -z "$M_TRUST_ZH" ] || say_zh "                   $M_TRUST_ZH";;
    keep) say "  node software  : keep the bitcoind already installed (your choice)";; *) say "  node software  : your Bitcoin Knots build ($KNOTS_CHOICE)";; esac
  case "$GW_CHOICE" in alphapool) say "  gateway        : AlphaPool's DATUM gateway release $GW_VER (tested pin)";;
    keep) say "  gateway        : keep the gateway already installed (your choice)";; *) say "  gateway        : your DATUM gateway build ($GW_CHOICE)";; esac
  case "$SYNC_MODE" in
    assumeutxo)
      if [ "$CHAIN_PRESENT" = 1 ]; then say "  chain data     : keep the chain data already on this server"
      elif [ -n "$UX_URL" ]; then
        say "  chain data     : the validated start. Your node loads the UTXO snapshot of block $(sep "$UX_HEIGHT") ($(gb "$UX_BYTES") GB"
        say "                   download, sha256 checked; Bitcoin Knots checks its content against a hash compiled into it),"
        say "                   then validates every block since then by itself: $(catchup_about). You see the blocks left"
        say "                   and the time left. KEEP YOUR RIGS MINING WHERE THEY ARE until this says READY."
      else say "  chain data     : the validated start (the UTXO snapshot is chosen once your Bitcoin Knots build is installed)"; fi;;
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
  local ans="" logged=0
  if [ -n "$TEE_PID" ]; then logged=1; flush_tee || die AP-100 "could not finish writing the plan to the terminal"; fi
  { IFS= read -r -p "Type yes to install, anything else to stop: " ans < /dev/tty; } 2>/dev/tty || true
  [ "$logged" = 0 ] || start_tee
  [ "$ans" = yes ] || { say "Stopped. Nothing was changed."; drain; exit 1; }
}
save_settings(){
  install -d -m 0755 "$ETC"
  [ -e "$CONF" ] || { printf '# AlphaPool node settings (written by the installer; change them by running it again)\n' > "$CONF"; chmod 0644 "$CONF"; }
  kv_set "$CONF" ADDRESS "$ADDRESS"; kv_set "$CONF" TAG "$TAG"
  kv_set "$CONF" STRATUM_PORT "$STRATUM_PORT"; kv_set "$CONF" ALIAS_PORTS "$ALIAS_PORTS"
  kv_set "$CONF" PUBLIC_HOST "$PUBLIC_HOST"; kv_set "$CONF" SYNC_MODE "$SYNC_MODE"; kv_set "$CONF" START_MODE "$START_MODE"
  kv_set "$CONF" FIREWALL "$FIREWALL"; kv_set "$CONF" PORT_CHECK "$PORT_CHECK"
  kv_set "$CONF" HEARTBEAT "$HEARTBEAT"; kv_set "$CONF" NODE_ID "$NODE_ID"; kv_set "$CONF" SSH_PORTS "$SSH_PORTS"
  kv_set "$CONF" UTXO_URL "$UTXO_URL"; kv_set "$CONF" UTXO_SHA256 "$UTXO_SHA256"       # empty unless you named a snapshot of your own
  kv_set "$CONF" UTXO_TORRENT "$UTXO_TORRENT"; kv_set "$CONF" UTXO_SEED "$UTXO_SEED"
  kv_set "$CONF" UTXO_BYTES "$UTXO_BYTES"; kv_set "$CONF" UTXO_HEIGHT "$UTXO_HEIGHT"
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
  new_file "$dest" || { say "  $dest cannot be made as a new file"; return 1; }
  if is_dry; then
    [ -n "${AP_DRY_FIXTURES:-}" ] && [ -f "$AP_DRY_FIXTURES/$name" ] && { cat "$AP_DRY_FIXTURES/$name" > "$dest"; return $?; }
    say "  DRY: no fixture for $name"; return 1
  fi
  for i in 1 2 3 4 5; do
    new_file "$dest.part" && curl -fsSL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" && mv -f "$dest.part" "$dest" && return 0
    say "  download of $name failed (attempt $i of 5), retrying in 15 s"; sleep 15
  done
  return 1
}
# Downloads from a server that admits a few downloads at a time (AlphaPool's snapshot server). When
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
  local url=$1 dest=$2 total=$3 label=$4 dir name errors=0 rc st before p
  dir=$(dirname "$dest"); name=$(basename "$dest")
  for p in "$dest" "$dest.aria2"; do       # only a plain file of root's is continued; anything else with that name goes
    if [ -e "$p" ] || [ -L "$p" ]; then plain_own "$p" || rm -rf -- "$p"; fi
  done
  if is_dry && [ "${AP_DRY_REAL_DOWNLOAD:-0}" != 1 ]; then
    local fx=${AP_DRY_FIXTURES:-}/${url##*/}
    [ -n "${AP_DRY_FIXTURES:-}" ] && [ -f "$fx" ] && { cat "$fx" > "$dest"; return $?; }
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
PKGS="curl jq aria2 ufw gpgv ca-certificates iptables libcurl4-openssl-dev libjansson-dev libmicrohttpd-dev libsodium-dev"
BUILD_PKGS="build-essential cmake pkg-config git"
apt_install(){
  if is_dry; then printf 'DRY: apt-get install %s\n' "$*" >> "$PLAN"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1   # 22.04's needrestart is interactive by default
  local try alog=$LOGD/apt.log last
  work_dir; last=$WORK/apt.last
  for try in 1 2 3; do
    # first boot: cloud-init or the automatic updates may hold the package lock for a while; wait instead of failing.
    # apt's own output goes to its own log; its tail is shown only if it fails.
    if { apt-get -o DPkg::Lock::Timeout=1200 update -qq \
           && apt-get -o DPkg::Lock::Timeout=1200 -o Dpkg::Options::=--force-confold install -y -qq --no-install-recommends "$@"; } \
         > "$last" 2>&1; then
      cat "$last" >> "$alog"; rm -f "$last"; return 0
    fi
    cat "$last" >> "$alog"; tail -n 8 "$last" | sed 's/^/  apt: /'
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
  install -d -o "$U" -g "$U" -m 0750 "$HOME_U"
  # Inside the node user's home, that user's own process makes the folders. Root changes no owner or mode in there
  # and writes no file there: a link planted in those folders could otherwise point root at any file on the server.
  as_u mkdir -p -m 0750 "$DD" "$GWD" || die AP-502 "the folders of the user $U could not be made"
  local d
  for d in "$DD" "$GWD"; do
    has_u -d "$d" && has_u -O "$d" || die AP-502 "$d does not belong to the user $U. The installer does not change owners in that user's home; give the folder back yourself (chown -R $U:$U $d), then run again."
  done
  install -d -m 0755 "$ETC" "$LIB" "$RUN"
  work_dir
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
  # An install interrupted by a reboot continues by itself at the next boot (cloud-init only runs once), and an
  # upgrade that a crash or a power cut interrupted is finished or undone. Without one of the two markers it does nothing.
  write_managed "$UNITS/alphapool-install-resume.service" 0644 <<'UNIT'
[Unit]
Description=Continue an interrupted AlphaPool node install or upgrade
After=network-online.target
Wants=network-online.target
ConditionPathExists=|/etc/alphapool/install-in-progress
ConditionPathExists=|/etc/alphapool/upgrade.journal
ConditionPathExists=|/etc/alphapool/network-paused
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
# alphapool heartbeat agent (v6): the OPTIONAL status report from a self-hosted AlphaPool node to its owner's
# dashboard. Runs as the unprivileged node user every 20 s; the token arrives through systemd's LoadCredential.
# SENDS: node sync progress and peers, chain-snapshot restore progress, whether the node and the gateway run, how many
#        rigs are connected, whether the live job pays AlphaPool, the stratum host:port, the sha256 of the gateway
#        executable that runs, the version line of the installed bitcoind and the installer's version.
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
VERSIONS=${AP_HB_VERSIONS:-/etc/alphapool/versions}
BITCOIND=${AP_HB_BITCOIND:-/usr/local/bin/bitcoind}

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
# versions, as plain printable text without quotes or backslashes (they go into the JSON below)
kver=$(timeout 5 "$BITCOIND" -version 2>/dev/null | head -n 1 | tr -cd ' -~' | tr -d '"\\' | head -c 80)
iver=$(sed -n 's/^installer=//p' "$VERSIONS" 2>/dev/null | tail -1 | tr -cd ' -~' | tr -d '"\\' | head -c 40)
if   [ "$ns" != active ] && [[ $rst =~ ^(downloading|verifying|extracting)$ ]]; then ph=restoring
elif [ "$ns" != active ];                                  then ph=starting
elif [ "$ibd" = true ];                                    then ph=syncing
elif awk "BEGIN{exit !($pg < 0.9999)}";                    then ph=syncing
elif [ "$gs" != active ];                                  then ph=gateway-starting
elif [ "$payees" -gt 0 ] && [ "$rigs" -gt 0 ];             then ph=mining
elif [ "$payees" -gt 0 ];                                  then ph=ready
else                                                            ph=connecting
fi
body=$(printf '{"node_id":"%s","ts":%s,"phase":"%s","node":{"state":"%s","height":%s,"headers":%s,"progress":%s,"ibd":%s,"peers":%s,"size_on_disk":%s},"endpoint":{"host":"%s","port":%s},"gateway":{"state":"%s","coinbase_payees":%s,"rigs":%s,"exe_sha256":"%s"},"restore":{"state":"%s","bytes":%s,"total":%s},"software":{"knots":"%s","installer":"%s"},"agent":{"v":6}}' \
  "$NODE_ID" "$(date -u +%s)" "$ph" "$ns" "$h" "$hd" "$pg" "$ibd" "$peers" "$sz" "$pub" "$(int "$STRATUM_PORT")" \
  "$gs" "$payees" "$rigs" "$exe" "$rst" "$rb" "$rt" "$kver" "$iver")
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
#   alphapool-gateway-start (/etc/systemd/system); settings /etc/alphapool/node.conf; logs /var/lib/alphapool/log/.
# Edit any of them by hand: re-running the installer keeps your edits and your software choices.
set -uo pipefail
export LC_ALL=C
INSTALLER=/usr/local/lib/alphapool/install.sh
ETC=/etc/alphapool
DD=/home/alphapool/.bitcoin
GWD=/home/alphapool/datum_gateway
LOG=/var/lib/alphapool/log/install.log
usage(){ cat <<'U'
alphapool-node status                       node, gateway, rigs, payout address, heartbeat, warnings
alphapool-node status --watch               progress every minute until READY (Ctrl-C stops watching only)
alphapool-node logs [node|gateway|install]  recent log lines
alphapool-node start|stop|restart [node|gateway|all]   (stop: until the next reboot)
alphapool-node disable | enable             keep the node and gateway off across reboots / turn them back on
alphapool-node heartbeat off | on <node id> | status   the optional status report to your AlphaPool dashboard
alphapool-node switch gateway alphapool                      AlphaPool's tested gateway build
alphapool-node switch gateway file /path/to/datum_gateway    a gateway binary you built or downloaded
alphapool-node switch gateway url URL SHA256                 a gateway release (archive or binary) + its sha256
alphapool-node switch gateway git REPO_URL COMMIT            build a DATUM gateway from source
alphapool-node switch knots alphapool                        AlphaPool's tested Bitcoin Knots build
alphapool-node switch knots url URL [SHA256]                 another Knots release archive (.tar.gz). Without SHA256
                                                             its builder signatures must be valid; with SHA256
                                                             yours decides (signature problems: a warning)
alphapool-node switch knots dir /path                        bitcoind + bitcoin-cli you built
alphapool-node set address <payout address>  |  set tag "<block name>"
alphapool-node gateway-page                 how to open the gateway's own web page (through SSH)
alphapool-node upgrade check                is a newer installer published? (downloads it; runs nothing)
alphapool-node upgrade <sha256> [--yes]     download the published installer, refuse it unless its sha256 is the one your
                                            dashboard (or the CHANGELOG) shows, then run its upgrade (it asks first)
alphapool-node upgrade [--yes]              move Bitcoin Knots and the gateway to the versions pinned by the installer on
                                            this server (the last one you downloaded and ran), in place, with a way back.
                                            Your own builds are left alone unless you add --knots alphapool / --gateway alphapool
alphapool-node repair                       run this node's installer again with its saved settings
alphapool-node uninstall [--keep-chain]     remove everything the installer added
U
  local src; src=$(bash "$INSTALLER" --pins 2>/dev/null | sed -n 's/^gateway_built_from=//p')
  [ -z "$src" ] || echo "The source of AlphaPool's gateway build, to build it yourself: alphapool-node switch gateway git $src"
}
need_root(){ [ "$(id -u)" = 0 ] || { echo "run it as root: sudo alphapool-node $*"; exit 1; }; }
english_console(){
  [ "${TERM:-}" = linux ] && return 0
  case "$(tty 2>/dev/null)" in /dev/tty1|/dev/ttyS0) return 0;; esac
  local output_pid=$BASHPID
  case "$(readlink "/proc/$output_pid/fd/1" 2>/dev/null)" in /dev/tty1|/dev/ttyS0) return 0;; esac
  return 1
}
# Whatever lives in the node user's folders is read by a process of that user, never by root: the data folder with
# bitcoin.conf, the gateway folder, and bitcoin-cli itself, which reads bitcoin.conf and the RPC cookie.
as_u(){ ( cd / 2>/dev/null; exec env HOME=/home/alphapool USER=alphapool LOGNAME=alphapool setpriv --reuid=alphapool --regid=alphapool --init-groups -- "$@" ); }
cli(){ as_u timeout 4 /usr/local/bin/bitcoin-cli -datadir="$DD" "$@"; }       # never waits longer than 4 s for the node
val(){ sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1; }
sep(){ printf '%s' "$1" | sed -E ':a;s/^([0-9]+)([0-9]{3})/\1,\2/;ta'; }
eta_text(){
  local s=$1
  if [ "$s" -lt 300 ]; then printf 'under 5 min'
  elif [ "$s" -lt 5400 ]; then printf 'about %d min' $(( (s + 150) / 300 * 5 ))
  else printf 'about %d h %02d min' $(( s / 3600 )) $(( s % 3600 / 600 * 10 )); fi
}
status(){
  local port addr tag info b h ibd peers ns gs rigs payees host w res pins why nodeline eta ts cs ncs bgb sh late=0 age gwsha A kv reqh
  port=$(val STRATUM_PORT $ETC/node.conf); port=${port:-23334}
  addr=$(val ADDRESS $ETC/node.conf); tag=$(val TAG $ETC/node.conf)
  res=$(cat $ETC/last-result 2>/dev/null)
  ns=$(systemctl is-active knots-node 2>/dev/null); gs=$(systemctl is-active datum-gateway 2>/dev/null)
  # Every question to the node is bounded (4 s): while it validates blocks it can take long to answer. After the first
  # question that gets no answer in time no more are asked, and the figures the gateway starter wrote are shown.
  # ask puts the answer into A. It is never called inside $( ): `late` has to outlive the call.
  ask(){ local rc; A=""; [ $late = 0 ] || return 1; A=$(cli "$@" 2>/dev/null); rc=$?; [ $rc -ne 124 ] || late=1; [ $rc -eq 0 ] || A=""; return $rc; }
  ask getblockchaininfo; info=$A
  rigs=$(ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l)
  payees=$(timeout 3 curl -sS http://127.0.0.1:7152/coinbaser 2>/dev/null | head -c 200000 \
           | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${addr:-none}")
  why="the gateway has no AlphaPool job yet"
  [ "$gs" = active ] || why="the gateway starts when the node is at the chain tip"
  eta=""; ts=$(val ts /run/alphapool/sync-progress); w=$(val eta_s /run/alphapool/sync-progress); age=999999
  [[ ${ts:-} =~ ^[0-9]+$ ]] && age=$(( $(date +%s) - ts ))
  if [ "$age" -le 300 ] && [[ ${w:-} =~ ^[0-9]+$ ]]; then eta=", $(eta_text "$w") at the current speed"; fi
  if [ -n "$info" ]; then
    b=$(jq -r .blocks <<<"$info"); h=$(jq -r .headers <<<"$info"); ibd=$(jq -r .initialblockdownload <<<"$info")
    ask getconnectioncount; peers=${A:-?}
    if [ "$ibd" = false ] && [ "$b" = "$h" ]; then nodeline="$ns, at the tip (block $b), $peers peers"
    elif [ "$b" = "$h" ]; then nodeline="$ns, getting block headers from peers (block $b), $peers peers"; why="the node is getting the block headers"
    else
      nodeline="$ns, catching up: block $b of $h ($((h - b)) to go$eta), $peers peers"
      why="the node is validating blocks: $(sep $((h - b))) left$eta"
    fi
  elif [ "$age" -le 120 ]; then        # the node is busy; the gateway starter asked it less than two minutes ago
    b=$(val blocks /run/alphapool/sync-progress); h=$(val headers /run/alphapool/sync-progress)
    nodeline="$ns, catching up: block $b of $h ($((h - b)) to go$eta); the node is busy and did not answer within 4 s, these figures are $age s old"
    why="the node is validating blocks: $(sep $((h - b))) left$eta"
  elif [ $late = 1 ]; then nodeline="$ns (busy: no answer within 4 s; try again in a moment)"; why="the node is busy and did not answer"
  else nodeline="$ns (not answering yet: starting or loading the chain)"; why="the node is not answering yet"; fi
  [ ! -e $ETC/install-in-progress ] || why="the install is still running: $(cat /run/alphapool/install-status 2>/dev/null)"
  if [ "${1:-}" = watch ]; then
    # Reuse the normal bounded probes and READY check. Estimate only from fresh RPC
    # samples observed by this watch, never from a fixed duration or stale cache.
    local now left remaining="time left: measuring" stamp
    now=$(date +%s); stamp=$(date -u +%H:%M:%SZ)
    if [ "$gs" = active ] && [ "$payees" -gt 0 ]; then
      host=$(val PUBLIC_HOST $ETC/node.conf); [ -n "$host" ] || host=$(val DETECTED_HOST $ETC/node.conf)
      [ -n "$host" ] || host=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
      printf '%s READY - point rigs at stratum+tcp://%s:%s (worker: anything)\n' "$stamp" "$host" "$port"
      return 0
    fi
    if [ -n "$info" ] && [[ ${b:-} =~ ^[0-9]+$ ]] && [[ ${h:-} =~ ^[0-9]+$ ]] && [ "$h" -ge "$b" ]; then
      left=$((h - b))
      if [ -e "$ETC/install-in-progress" ] || [ -e "$ETC/validated-start.journal" ]; then
        # Loading a snapshot jumps the height without validating that many blocks.
        WATCH_BLOCKS=-1; WATCH_TIME=$now
        remaining="the install is still running; time left: unavailable"
      else
        if [ "${WATCH_BLOCKS:--1}" -ge 0 ] && [ "$now" -gt "$WATCH_TIME" ]; then
          if [ "$b" -gt "$WATCH_BLOCKS" ]; then
            remaining="time left: $(eta_text "$(( left * (now - WATCH_TIME) / (b - WATCH_BLOCKS) ))") at the measured speed"
          elif [ "$b" = "$WATCH_BLOCKS" ]; then remaining="no new blocks since the last check; time left: unavailable"
          else remaining="chain changed; time left: measuring"; fi
        fi
        WATCH_BLOCKS=$b; WATCH_TIME=$now
      fi
      [ "$left" -ne 0 ] || remaining="$why; time left: unavailable"
      printf '%s NOT READY - block %s of %s; %s blocks left; %s; %s peers\n' "$stamp" "$b" "$h" "$left" "$remaining" "${peers:-?}"
    else
      WATCH_BLOCKS=-1; WATCH_TIME=$now
      printf '%s NOT READY - %s; blocks left: unavailable; time left: unavailable; peers: unavailable\n' "$stamp" "$why"
    fi
    return 1
  fi
  echo "AlphaPool node (installer $(val installer_version $ETC/state))"
  if [ "$gs" = active ] && [ "$payees" -gt 0 ]; then echo "  state    : READY - your rigs can mine here"
  else echo "  state    : NOT READY yet - keep your rigs mining where they are ($why)"; fi
  if [ -e $ETC/install-in-progress ]; then echo "  install  : running - $(cat /run/alphapool/install-status 2>/dev/null)"
  else case "$res" in
    ok*) echo "  install  : complete";;
    upgrade-failed*) echo "  install  : complete"
      echo "  upgrade  : the last upgrade did not go through (${res#upgrade-failed }); the software from before it is running";;
    upgrade-waiting*) echo "  install  : complete"
      echo "  upgrade  : done; the gateway was not back when it ended (it starts once the node is at the tip)";;
    failed*) echo "  install  : FAILED (${res#failed }) - see: alphapool-node logs install";;
  esac; fi
  if [ -e $ETC/upgrade.journal ]; then
    if flock -n /run/alphapool-node-install.lock true 2>/dev/null; then
      echo "  upgrade  : one was cut short. It is finished at the next start of the server, or now: sudo alphapool-node upgrade"
    else echo "  upgrade  : running - $(cat /run/alphapool/install-status 2>/dev/null)"; fi
  fi
  echo "  node     : $nodeline"
  # how this node got its chain; after a validated start the history before the snapshot is checked in the background
  ask getchainstates; cs=$A; ncs=$(jq -r '.chainstates | length' <<<"$cs" 2>/dev/null)
  sh=$(val chain_start_height $ETC/state)
  if [ -z "$cs" ] && [ "$(val chain_start $ETC/state)" = assumeutxo ] && [ -n "$ns" ] && [ "$ns" != inactive ]; then
    echo "  chain    : validated start from the UTXO snapshot of block $(sep "${sh:-?}"); this node validates every block since itself"
  elif [ "${ncs:-0}" = 2 ]; then
    bgb=$(jq -r '.chainstates[0].blocks' <<<"$cs" 2>/dev/null)
    [[ ${sh:-} =~ ^[1-9][0-9]*$ ]] || { ask getblockheader "$(jq -r '.chainstates[1].snapshot_blockhash' <<<"$cs")"; sh=$(jq -r '.height // empty' <<<"$A" 2>/dev/null); }
    echo "  chain    : validated start from the UTXO snapshot of block $(sep "${sh:-?}"); this node validates every block since itself"
    if [[ ${sh:-} =~ ^[1-9][0-9]*$ ]] && [[ ${bgb:-} =~ ^[0-9]+$ ]]; then
      echo "             history check: block $(sep "$bgb") of $(sep "$sh") ($(( bgb * 100 / sh ))%). It runs in the background and does not affect mining"
    fi
  elif [ "${ncs:-0}" = 1 ] && [ -n "$(jq -r '.chainstates[0].snapshot_blockhash // empty' <<<"$cs" 2>/dev/null)" ]; then
    echo "  chain    : validated start; the history check is complete: this node has validated the whole chain itself"
  elif [ "${ncs:-0}" = 1 ] && [ "$(val chain_start $ETC/state)" = assumeutxo ]; then
    echo "  chain    : validated by this node itself (validated start, history check complete)"
  fi
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
  w=$(val gateway_label $ETC/state); gwsha=$(as_u sha256sum "$GWD/datum_gateway" 2>/dev/null | cut -d' ' -f1)
  echo "             DATUM gateway ${w:+$w, }sha256 ${gwsha:0:16}... [$(val gateway_source $ETC/state)]"
  w=$(val gateway_built_from $ETC/versions); [ -z "$w" ] || echo "             (its source: $w)"
  pins=$(bash "$INSTALLER" --pins 2>/dev/null)
  pin(){ printf '%s\n' "$pins" | sed -n "s/^$1=//p" | head -1; }
  if [ "$(val knots_source $ETC/state)" = alphapool ] && [ -n "$(pin start_mode)" ]; then
    echo "             start mode: $(pin start_mode) - $(pin start_label)$([ "$(pin start_signed)" = builders ] || echo ' (not signed by the Bitcoin Knots release builders)')"
    echo "             archive sha256: $(val knots_pin $ETC/state)"
    if [ "$(pin start_signed)" != builders ]; then
      echo "             $(pin start_trust)"
      english_console || { [ -z "$(pin start_trust_zh)" ] || echo "             $(pin start_trust_zh)"; }
    fi
  fi
  if [ "$(val knots_source $ETC/state)" = alphapool ] && [ -n "$(pin start_gone)" ]; then
    echo "  upgrade  : the installer on this server has no start mode '$(pin start_gone)' any more: Bitcoin Knots stays as it is"
    echo "             (to move it to a start mode of that installer: sudo alphapool-node upgrade --start NAME)"
  elif [ "$(val knots_source $ETC/state)" = alphapool ] && [ -n "$(pin knots_pin)" ] && [ "$(val knots_pin $ETC/state)" != "$(pin knots_pin)" ]; then
    echo "  upgrade  : newer pinned version available: Bitcoin Knots $(pin knots_version) - run: sudo alphapool-node upgrade"
  fi
  if [ "$(val gateway_source $ETC/state)" = alphapool ] && [ -n "$(pin gateway_pin)" ] && [ "$gwsha" != "$(pin gateway_pin)" ]; then
    w=$(pin gateway_pin)             # the label alone can be the same for two builds of one release: the sha256 tells them apart
    echo "  upgrade  : newer pinned build available: DATUM gateway $(pin gateway_label), sha256 ${w:0:12}... - run: sudo alphapool-node upgrade"
  fi
  # the soft-fork pin: a release every node must run from a given block (new consensus rules)
  w=$(pin knots_required_ver); [ -n "$w" ] || w=$(val knots_required_ver $ETC/versions)
  if [ -n "$w" ]; then
    kv=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1); reqh=$(pin knots_required_by_height); [ -n "$reqh" ] || reqh=$(val knots_required_by_height $ETC/versions)
    case "$kv" in *"$w"*) ;; *)
      echo "  UPDATE   : Bitcoin Knots $w is required from block $(sep "${reqh:-?}") (new consensus rules; this node: block $(sep "${b:-?}"))."
      echo "             Update before that block: sudo alphapool-node upgrade check";; esac
  fi
  echo "  updates  : nothing updates by itself - a newer installer published? alphapool-node upgrade check"
  if systemctl is-enabled --quiet alphapool-heartbeat.timer 2>/dev/null; then echo "  heartbeat: on (status only) - turn off: alphapool-node heartbeat off"
  else echo "  heartbeat: off (nothing is reported to AlphaPool)"; fi
  w=$(as_u cat "$DD/bitcoin.conf" 2>/dev/null | sed -n 's/^[[:space:]]*blockmaxweight[[:space:]]*=[[:space:]]*//p' | head -1)
  if ! [[ ${w:-x} =~ ^[0-9]+$ ]] || [ "$w" -gt 740000 ]; then
    echo "  WARNING  : blockmaxweight=${w:-default} in $DD/bitcoin.conf; AlphaPool's payout requirement is 740000 or lower"
    echo "             (AlphaPool pays miners in the block's coinbase; above it the payout list may not fit)"
  fi
}
status_watch(){
  local WATCH_BLOCKS=-1 WATCH_TIME=0 watch_sleep=""
  # Only this command's own wait process is stopped; no service or node signal.
  trap '[ -z "$watch_sleep" ] || kill "$watch_sleep" 2>/dev/null; exit 130' INT
  trap '[ -z "$watch_sleep" ] || kill "$watch_sleep" 2>/dev/null; exit 143' TERM
  until status watch; do
    sleep 60 & watch_sleep=$!
    wait "$watch_sleep"; watch_sleep=""
  done
  trap - INT TERM
}
# upgrade_fetch: the published installer, by you. `check` downloads it to the installer's work area, compares it with
# the installed copy and runs nothing. `<sha256>` downloads it and runs its --upgrade only if its sha256 is the one you
# give (from your AlphaPool dashboard "My node", or the CHANGELOG in the installer's repository): the same check the
# first install made. Nothing updates by itself, and AlphaPool cannot push an update: this command is yours to run.
upgrade_fetch(){
  local what=${1:-check} url f sha cur ver
  url=$(sed -n 's/^INSTALLER_URL="\(https:[^"]*\)".*/\1/p' "$INSTALLER" | head -1)
  cur=$(sha256sum "$INSTALLER" 2>/dev/null | cut -c1-64)
  [ -n "$url" ] || { echo "no installer URL in $INSTALLER"; exit 1; }
  if [ "$what" != check ]; then
    [[ $what =~ ^[0-9a-f]{64}$ ]] || { usage; exit 1; }
    [ "$what" != "$cur" ] || { echo "the installer with sha256 $cur is already on this node; to repeat its upgrade: sudo alphapool-node upgrade"; exit 0; }
  fi
  mkdir -p /var/lib/alphapool/dl && chmod 0700 /var/lib/alphapool /var/lib/alphapool/dl || exit 1
  f=/var/lib/alphapool/dl/ap-node-published.sh
  rm -f "$f"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$f" "$url" || { rm -f "$f"; echo "could not download $url"; exit 1; }
  sha=$(sha256sum "$f" | cut -c1-64); ver=$(sed -n 's/^AP_VERSION="\([^"]*\)".*/\1/p' "$f" | head -1)
  case "$what" in
    check)
      rm -f "$f"
      echo "installed: installer $(val installer_version $ETC/state)  sha256 $cur"
      echo "published: installer ${ver:-?}  sha256 $sha  ($url)"
      if [ "$sha" = "$cur" ]; then echo "this node runs the published installer: nothing to update"; exit 0; fi
      echo "A different installer is published. Nothing was run. If its sha256 is the one your AlphaPool dashboard"
      echo "(My node) or the CHANGELOG at https://github.com/alphaminetech/alphapool-node-installer shows, upgrade with:"
      echo "  sudo alphapool-node upgrade $sha";;
    *)
      if [ "$sha" != "$what" ]; then
        rm -f "$f"; echo "the downloaded installer has sha256 $sha, not $what: NOT run (deleted). Check the sha256 on your dashboard and try again."; exit 1
      fi
      echo "installer ${ver:-?} downloaded, sha256 matches: its upgrade now runs (it shows what changes and asks first)"
      exec bash "$f" --upgrade "${@:2}";;
  esac
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
  status) need_root status
          case "${2:-}" in
            "") [ "$#" -le 1 ] || { usage; exit 1; }; status;;
            --watch) [ "$#" = 2 ] || { usage; exit 1; }; status_watch;;
            *) usage; exit 1;;
          esac;;
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
       "knots url") if [ -n "${5:-}" ]; then exec bash "$INSTALLER" --repair --knots-url "${4:?url}" --knots-sha256 "$5"
                    else exec bash "$INSTALLER" --repair --knots-url "${4:?url}"; fi;;
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
     echo "Its admin pages ask for user 'admin' and this password: $(as_u cat "$GWD/datum_gateway_config.json" 2>/dev/null | jq -r .api.admin_password 2>/dev/null)";;
  upgrade) need_root upgrade
     case "${2:-}" in
       check|[0-9a-f]*) upgrade_fetch "${@:2}";;
       *) exec bash "$INSTALLER" --upgrade "${@:2}";;
     esac;;
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
write_managed(){   # FILE MODE [user] < content. "user": FILE is in a folder of the node user's, so that user's process writes it
  local f=$1 mode=$2 as=${3:-} key new_sha cur_sha rec_sha tmp
  key="file:$f"
  if [ -n "$as" ]; then work_dir; tmp=$(mktemp "$WORK/wm.XXXXXX") || return 1
  else tmp=$(mktemp "$f.XXXXXX.tmp") || return 1; fi           # mktemp creates it 0600
  cat > "$tmp"; chmod "$mode" "$tmp"
  new_sha=$(sha_of "$tmp")
  if if [ -n "$as" ]; then has_u -e "$f"; else [ -e "$f" ]; fi; then
    if [ -n "$as" ]; then cur_sha=$(sha_u "$f"); else cur_sha=$(sha_of "$f"); fi
    rec_sha=$(kv_get "$STATE" "$key" || true)
    if [ "$cur_sha" = "$new_sha" ]; then rm -f "$tmp"; kv_set "$STATE" "$key" "$new_sha"; WM_RESULT=same; return 0; fi
    if [ "$cur_sha" != "$rec_sha" ]; then
      wm_put "$f.alphapool-new"
      say "  kept your edited $f (the installer's version is in $f.alphapool-new)"
      WM_RESULT=kept; return 0
    fi
  fi
  wm_put "$f" || return 1
  kv_set "$STATE" "$key" "$new_sha"
  if [ -n "$as" ]; then as_u rm -f "$f.alphapool-new"; else rm -f "$f.alphapool-new"; fi
  WM_RESULT=written
}
wm_put(){ local r; if [ -n "$as" ]; then put_as_user "$1" "$mode" < "$tmp"; r=$?; rm -f "$tmp"; else mv -f "$tmp" "$1"; r=$?; fi; return "$r"; }   # write_managed's last step
# put_as_user DEST MODE < content: DEST lies in a folder that belongs to the node user, so a process of THAT user writes
# it and root only hands over the content. A link planted in that folder then reaches nothing its owner could not reach.
put_as_user(){
  as_u sh -c 'umask 077; rm -f -- "$1.aptmp"; cat > "$1.aptmp" && chmod "$2" "$1.aptmp" && mv -T -f -- "$1.aptmp" "$1"' _ "$1" "$2"
}

# ==== software sets: how the programs are installed and switched ======================================================
# Every combination of programs the installer installs is a "set": a directory of its own under
# /usr/local/lib/alphapool/sets, named after what is in it, holding bitcoind, bitcoin-cli and datum_gateway plus
# set.info (their sha256 and where they came from). /usr/local/lib/alphapool/current is a link to the active set,
# and the documented program paths (/usr/local/bin/bitcoind, /usr/local/bin/bitcoin-cli,
# /home/alphapool/datum_gateway/datum_gateway) are links into current/. Changing software is therefore ONE rename
# of the "current" link: all the programs change together, or none does. The set that was active before stays on
# disk as the way back. A file of your own at a documented path (in place of the link) is yours: it is in no set and
# nothing touches it unless you ask (--knots alphapool / --gateway alphapool).
K_NAMES="bitcoind bitcoin-cli"; G_NAMES="datum_gateway"
GW_SOURCE=""; GW_ORIGIN=""; GW_LABEL=""          # what the gateway staging found, like KN_* from knots_stage
doc_path(){ case "$1" in datum_gateway) printf '%s' "$GW_BIN";; *) printf '/usr/local/bin/%s' "$1";; esac; }
linked(){   # NAME comes from the active set (the gateway's path is in the node user's folder: looked at as that user)
  if [ "$1" = datum_gateway ]; then [ "$(as_u readlink "$GW_BIN" 2>/dev/null)" = "$CUR/$1" ]
  else [ -L "/usr/local/bin/$1" ] && [ "$(readlink "/usr/local/bin/$1")" = "$CUR/$1" ]; fi
}
active_set(){ local t; t=$(readlink "$CUR" 2>/dev/null) || return 1; t=${t#sets/}; [ -n "$t" ] && [ -d "$SETS/$t" ] && printf '%s' "$t"; }
set_verify(){   # SET: a real directory in which every file set.info lists is a plain file with the recorded sha256
  local d=$SETS/$1 line n any=1
  [ -n "$1" ] && [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/set.info" ] && [ ! -L "$d/set.info" ] || return 1
  while IFS= read -r line; do
    case "$line" in sha256:*)
      n=${line%%=*}; n=${n#sha256:}
      [ -f "$d/$n" ] && [ ! -L "$d/$n" ] && [ "$(sha_of "$d/$n")" = "${line#*=}" ] || return 1
      any=0;;
    esac
  done < "$d/set.info"
  return $any
}
# set_make KSRC GSRC -> SET_ID. For each component (K = bitcoind + bitcoin-cli, G = datum_gateway) SRC says what the set gets:
#   a directory  the files freshly staged and verified there;
#   cur          what is installed now at the documented paths (links or files of your own);
#   keep         what the active set serves now stays in the set unchanged; a file of your own stays out of it.
# The set is built under a temporary name; every copy is compared with the sha256 of its source; only a complete set
# gets its name (one rename). Nothing is ever half-made: on any failure the result is 1 and there is no new set.
# SET_ID stays empty (result 0) when there is nothing to put in a set, as on a fresh server.
SET_ID=""
set_make(){
  local ks=$1 gs=$2 tmp n src h info id kver="" gsha="" staged=0 v gcur=""
  SET_ID=""
  install -d -m 0755 "$LIB" "$SETS" || return 1
  if [ "$gs" = cur ]; then
    # The gateway file is in the node user's folder. A process of THAT user reads it, into root's scratch directory;
    # only this copy goes on. Root itself never opens the path: a link there to a file only root may read would
    # otherwise end up, readable for everybody, in a set.
    work_dir; gcur=$WORK/adopt-gateway; rm -rf "$gcur"; mkdir -m 0700 "$gcur" || return 1
    if has_u -f "$GW_BIN" && as_u cat "$GW_BIN" > "$gcur/datum_gateway" 2>/dev/null && [ -s "$gcur/datum_gateway" ]; then gs=$gcur
    else gs=""; fi
  fi
  tmp=$(mktemp -d "$SETS/.new.XXXXXXXX") || return 1
  chmod 0755 "$tmp"; info=$tmp/set.info
  printf 'format=1\n' > "$info" || { rm -rf "$tmp"; return 1; }
  for n in $K_NAMES $G_NAMES; do
    case "$n" in datum_gateway) src=$gs;; *) src=$ks;; esac
    case "$src" in
      "")   continue;;
      keep) linked "$n" || continue; src=$CUR;;
      cur)  [ "$n" != datum_gateway ] || continue                                  # (the gateway's "cur" became the copy in $gcur above)
            src=/usr/local/bin; [ -e "$src/$n" ] || continue;;                     # bitcoind and bitcoin-cli: /usr/local/bin is root's
      *)    [ "$src" = "$gcur" ] || staged=1;;
    esac
    h=$(sha_of "$src/$n")
    if [ -z "$h" ] || fault build || ! install -m 0755 "$src/$n" "$tmp/$n" || [ "$(sha_of "$tmp/$n")" != "$h" ]; then rm -rf "$tmp"; return 1; fi
    printf 'sha256:%s=%s\n' "$n" "$h" >> "$info"
  done
  if ! grep -q '^sha256:' "$info"; then rm -rf "$tmp"; return 0; fi
  if grep -q '^sha256:bitcoin' "$info"; then
    if [ "$ks" = keep ] || [ "$ks" = cur ]; then
      v=$(kv_get "$STATE" knots_source || true); [ "$v" = alphapool ] && ! knots_untouched && v="by-hand"
      printf 'knots_source=%s\nknots_origin=%s\nknots_pin=%s\n' "${v:-by-hand}" "$(kv_get "$STATE" knots_origin || true)" "$(kv_get "$STATE" knots_pin || true)" >> "$info"
    else printf 'knots_source=%s\nknots_origin=%s\nknots_pin=%s\n' "$KN_SOURCE" "$KN_ORIGIN" "$KN_PIN" >> "$info"; fi
    [ ! -f "$tmp/bitcoind" ] || printf 'knots_installed_sha256=%s\n' "$(sha_of "$tmp/bitcoind")" >> "$info"
    [ ! -f "$tmp/bitcoin-cli" ] || printf 'knots_cli_installed_sha256=%s\n' "$(sha_of "$tmp/bitcoin-cli")" >> "$info"
    kver=$(timeout 10 "$tmp/bitcoind" -version 2>/dev/null | head -1 | sed -E 's/^.* version //' | tr -cd 'A-Za-z0-9._-' | cut -c1-40)
    kver=${kver:-unknown}
  fi
  if grep -q '^sha256:datum_gateway=' "$info"; then
    gsha=$(sha_of "$tmp/datum_gateway")
    if [ "$gs" = keep ] || [ "$gs" = "$gcur" ]; then
      v=$(kv_get "$STATE" gateway_source || true); [ "$v" = alphapool ] && ! gw_untouched && v="by-hand"
      printf 'gateway_source=%s\ngateway_origin=%s\ngateway_label=%s\n' "${v:-by-hand}" "$(kv_get "$STATE" gateway_origin || true)" \
        "$([ "$v" = alphapool ] && kv_get "$STATE" gateway_label || true)" >> "$info"
      [ "$v" = alphapool ] && [ -f "$ETC/gateway.buildinfo" ] && install -m 0644 "$ETC/gateway.buildinfo" "$tmp/BUILDINFO"
    else
      printf 'gateway_source=%s\ngateway_origin=%s\ngateway_label=%s\n' "$GW_SOURCE" "$GW_ORIGIN" "$GW_LABEL" >> "$info"
      [ -f "$gs/BUILDINFO" ] && install -m 0644 "$gs/BUILDINFO" "$tmp/BUILDINFO"
    fi
    printf 'gateway_installed_sha256=%s\n' "$gsha" >> "$info"
  fi
  if [ $staged = 1 ]; then v=$AP_VERSION; else v=$(kv_get "$STATE" software_installer || true); fi
  printf 'software_installer=%s\n' "$v" >> "$info"
  id="${kver:+knots-$kver}${kver:+${gsha:+_}}${gsha:+gw-${gsha:0:8}}"
  id="${id}_$(sha256sum < "$info" | cut -c1-10)"            # same programs from the same sources = the same set
  printf 'created=%s\n' "$(date -u +%FT%TZ)" >> "$info"
  sync "$tmp"/* "$tmp" 2>/dev/null
  [ -z "$gcur" ] || rm -rf "$gcur"
  if [ -e "$SETS/$id" ] || [ -L "$SETS/$id" ]; then
    if set_verify "$id"; then rm -rf "$tmp"; SET_ID=$id; return 0; fi
    id="$id-$(rand_hex 3)"                                  # a damaged directory has that name: not used, removed by set_prune
  fi
  mv -T "$tmp" "$SETS/$id" || { rm -rf "$tmp"; return 1; }
  sync "$SETS" 2>/dev/null
  SET_ID=$id
}
set_switch(){   # SET: checked once more, then it becomes the active set in ONE rename of the "current" link
  local l=$LIB/.current.new
  set_verify "$1" || return 1
  fault switch && return 1
  rm -f "$l"
  ln -sT "sets/$1" "$l" && mv -T -f "$l" "$CUR" || { rm -f "$l"; return 1; }
  sync "$LIB" 2>/dev/null
  return 0
}
set_links(){   # K G (1 = that component's documented paths become links into the active set, which holds the same files already)
  local n p names=""
  [ "$1" = 1 ] && names=$K_NAMES
  [ "$2" = 1 ] && names="$names $G_NAMES"
  for n in $names; do
    linked "$n" && continue
    [ -e "$CUR/$n" ] || continue
    if [ "$n" = datum_gateway ]; then      # in the node user's folder: that user's own process makes the link
      as_u sh -c 'rm -f -- "$2.aplink"; ln -sT "$1" "$2.aplink" && mv -T -f "$2.aplink" "$2"' _ "$CUR/$n" "$GW_BIN" || return 1
    else p=/usr/local/bin/$n; rm -f "$p.aplink"; ln -sT "$CUR/$n" "$p.aplink" && mv -T -f "$p.aplink" "$p" || return 1; fi
  done
  return 0
}
set_state(){   # SET: the state file says what the active set holds (sources, sha256s, the installer that put it there)
  local d=$SETS/$1 line k
  while IFS= read -r line; do
    k=${line%%=*}
    case "$k" in knots_*|gateway_*|software_installer) kv_set "$STATE" "$k" "${line#*=}";; esac
  done < "$d/set.info"
  kv_set "$STATE" active_set "$1"
  if grep -q '^sha256:datum_gateway=' "$d/set.info"; then
    if [ -f "$d/BUILDINFO" ]; then install -m 0644 "$d/BUILDINFO" "$ETC/gateway.buildinfo"; else rm -f "$ETC/gateway.buildinfo"; fi
  fi
  return 0
}
set_prune(){   # the active set and the one before it stay; older ones and unfinished ones go
  local a p d
  a=$(active_set || true); p=$(kv_get "$STATE" previous_set || true)
  [ -n "$a" ] || return 0
  for d in "$SETS"/* "$SETS"/.new.*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    case "${d##*/}" in "$a"|"${p:-$a}") continue;; esac
    rm -rf -- "$d"
  done
  return 0
}
# set_adopt K G (1 = that component is about to change): afterwards the active set holds exactly the programs that
# are installed now for the components about to change (and for the ones it served already), and their documented
# paths are links into it. Each step leaves the same programs in place, so adopting never changes what runs.
# OLD_SET = that set ("" on a server with nothing installed yet).
OLD_SET=""
set_adopt(){
  local ks=keep gs=keep
  OLD_SET=""
  [ "$1" = 1 ] && ks=cur
  [ "$2" = 1 ] && gs=cur
  fault adopt && return 1
  set_make "$ks" "$gs" || return 1
  [ -n "$SET_ID" ] || return 0
  if [ "$(active_set || true)" != "$SET_ID" ]; then set_switch "$SET_ID" || return 1; fi
  set_links "$1" "$2" || return 1
  set_state "$SET_ID"
  OLD_SET=$SET_ID
}
# set_install KDIR GDIR ("" = that component stays as it is): staged software becomes the installed software in one
# switch (a fresh install, or a build you asked for). Services are not touched here.
set_install(){
  local k=0 g=0
  [ -n "$1" ] && k=1
  [ -n "$2" ] && g=1
  set_adopt "$k" "$g" || return 1
  set_make "${1:-keep}" "${2:-keep}" && [ -n "$SET_ID" ] || return 1
  if [ $k = 1 ] && ! snapshot_guard "$SETS/$SET_ID" "$([ "$KN_SOURCE" = alphapool ] && echo pinned)"; then
    rm -rf "${SETS:?}/$SET_ID"
    die AP-414 "this Bitcoin Knots build cannot run this node as it is. The node started from the UTXO snapshot of block $(sg_block) and has not finished checking the history before it; this build does not know that block${KN_HEIGHTS:+ (it knows the heights $KN_HEIGHTS)}. Switch when the history check is complete (alphapool-node status shows it). Nothing was changed."
  fi
  set_switch "$SET_ID" || return 1
  set_links "$k" "$g" || return 1
  set_state "$SET_ID"
  # the set from before is the way back, except while the first install is still putting the programs in place
  if [ -n "$OLD_SET" ] && [ "$OLD_SET" != "$SET_ID" ] && [ -n "$(kv_get "$STATE" installed_at || true)" ]; then kv_set "$STATE" previous_set "$OLD_SET"; fi
  set_prune
}

# ==== step 3: Bitcoin Knots ============================================================================================
NODE_CHANGED=0; GW_CHANGED=0
knots_untouched(){   # bitcoind AND bitcoin-cli are exactly what the installer put there
  local rec cli pin e
  rec=$(kv_get "$STATE" knots_installed_sha256) || return 1
  [ -n "$rec" ] && [ "$(sha_of /usr/local/bin/bitcoind)" = "$rec" ] || return 1
  cli=$(kv_get "$STATE" knots_cli_installed_sha256 || true)
  if [ -z "$cli" ]; then      # installed before 2026-10-07.2 (no record): only the bitcoin-cli of a known pin counts as untouched
    pin=$(kv_get "$STATE" knots_pin || true)
    for e in $KNOTS_CLI_KNOWN; do [ -n "$pin" ] && [ "${e%%:*}" = "$pin" ] && cli=${e#*:}; done
  fi
  [ -n "$cli" ] && [ "$(sha_of /usr/local/bin/bitcoin-cli)" = "$cli" ]
}
# ---- builder signatures of a Bitcoin Knots release ---------------------------------------------------------------
# sig_fetch BASE_URL DIR: 0 = SHA256SUMS and SHA256SUMS.asc are in DIR, 4 = they are not published there, 1 = download failed
sig_fetch(){
  local base=$1 d=$2 f st
  for f in SHA256SUMS.asc SHA256SUMS; do
    if is_dry; then [ -n "${AP_DRY_FIXTURES:-}" ] && [ -f "$AP_DRY_FIXTURES/$f" ] || return 4
    else probe_url "$base/$f"; st=$?; [ $st -eq 4 ] && return 4; fi
    fetch "$base/$f" "$d/$f" || return 1
  done
}
# knots_sig_check DIR: the valid signatures on DIR/SHA256SUMS made by PINNED builder keys -> SIG_SIGNERS (fingerprints).
# Succeeds with at least one. gpgv only knows the pinned keys; a signature counts only if gpgv calls it valid, its key
# is not expired or revoked, and the key's full fingerprint is in KNOTS_BUILDER_FPRS.
SIG_SIGNERS=""; SIG_OTHER=0
knots_sig_check(){
  local d=$1 out line fpr bad=0
  SIG_SIGNERS=""; SIG_OTHER=0
  command -v gpgv >/dev/null 2>&1 || return 1
  install -d -m 0700 "$d/gnupg"
  knots_keyring > "$d/builders.gpg" 2>/dev/null || return 1
  out=$(gpgv --homedir "$d/gnupg" --status-fd 1 --keyring "$d/builders.gpg" "$d/SHA256SUMS.asc" "$d/SHA256SUMS" 2>/dev/null)
  while IFS= read -r line; do
    case "$line" in
      "[GNUPG:] NEWSIG"*) bad=0;;
      "[GNUPG:] BADSIG"*|"[GNUPG:] EXPKEYSIG"*|"[GNUPG:] REVKEYSIG"*|"[GNUPG:] EXPSIG"*) bad=1; SIG_OTHER=$(( SIG_OTHER + 1 ));;
      "[GNUPG:] ERRSIG"*) SIG_OTHER=$(( SIG_OTHER + 1 ));;
      "[GNUPG:] VALIDSIG "*)
        fpr=${line##* }                               # last field: the primary key's full fingerprint
        if [ $bad -eq 0 ] && [[ " $KNOTS_BUILDER_FPRS " == *" $fpr "* ]]; then
          [[ " $SIG_SIGNERS " == *" $fpr "* ]] || SIG_SIGNERS="$SIG_SIGNERS $fpr"
        elif [ $bad -eq 0 ]; then SIG_OTHER=$(( SIG_OTHER + 1 )); fi;;
    esac
  done <<<"$out"
  [ -n "$SIG_SIGNERS" ]
}
sums_lists(){   # SUMS_FILE SHA256 NAME: exactly ONE line names the file, with exactly this name, and it carries this sha256.
  # A file that is listed twice (or once more under a path) is ambiguous, whatever the hashes say: refused.
  awk -v h="$2" -v n="$3" '
    { if (!match($0, /^[0-9A-Fa-f]+[ \t]+\*?/)) next
      name = substr($0, RLENGTH + 1); base = name; sub(/^.*\//, "", base)
      if (base == n) { listed++; if (name == n && $1 == h) ok++ } }
    END { exit !(listed == 1 && ok == 1) }' "$1"
}
knots_unpack(){   # TARBALL STAGE: ONLY <top>/bin/bitcoind and <top>/bin/bitcoin-cli come out, as plain files, into STAGE
  local t=$1 st=$2 bd bc kx l
  # (release archives carry library symlinks elsewhere; nothing but these two members is ever unpacked)
  l=$WORK/knots.list
  tar -tvzf "$t" > "$l" 2>/dev/null || { rm -f "$l"; die AP-403 "the Knots archive cannot be read"; }
  bd=$(awk 'substr($1,1,1) == "-" && $NF ~ /^[^\/.][^\/]*\/bin\/bitcoind$/ {print $NF; exit}' "$l")
  bc=$(awk 'substr($1,1,1) == "-" && $NF ~ /^[^\/.][^\/]*\/bin\/bitcoin-cli$/ {print $NF; exit}' "$l")
  rm -f "$l"
  [ -n "$bd" ] && [ -n "$bc" ] || die AP-403 "the Knots archive has no regular files <dir>/bin/bitcoind and <dir>/bin/bitcoin-cli"
  kx=$(mktemp -d "$WORK/knots.XXXXXX") || die AP-403 "the Knots archive could not be unpacked (no scratch directory)"
  tar -xzf "$t" -C "$kx" --no-same-owner "$bd" "$bc" || die AP-403 "the Knots archive could not be unpacked"
  { [ -f "$kx/$bd" ] && [ ! -L "$kx/$bd" ] && [ -f "$kx/$bc" ] && [ ! -L "$kx/$bc" ]; } \
    || { rm -rf "$kx"; die AP-402 "the Knots archive's bitcoind/bitcoin-cli are not plain files: refused"; }
  install -m 0755 "$kx/$bd" "$st/bitcoind" && install -m 0755 "$kx/$bc" "$st/bitcoin-cli" || die AP-403 "the Knots archive could not be unpacked"
  rm -rf "$kx"
}
# knots_stage REQ STAGE: download, verify and unpack a Knots build into STAGE; nothing is installed here, and every
# failure stops before anything is installed. REQ: "alphapool" | "url URL [SHA256]" | "dir DIR".
#   1. builder signatures: SHA256SUMS.asc must carry a valid signature from a pinned builder key, and SHA256SUMS must
#      list the archive. Required for AlphaPool's pin, and for your own URL unless you give its sha256 yourself.
#   2. the sha256: AlphaPool's pin (KNOTS_SHA256), or the one you gave. For AlphaPool's pin BOTH checks must pass.
KN_SOURCE=""; KN_ORIGIN=""; KN_PIN=""
knots_stage(){
  local req=$1 st=$2 kt url="" sha="" rc kd f signed=0 why=""
  work_dir; kt=$WORK/knots.tar.gz
  rm -rf "$st"; install -d -m 0700 "$st"
  case "$req" in
    alphapool) url=$KNOTS_URL; sha=$KNOTS_SHA256; KN_SOURCE=alphapool
               say "  downloading Bitcoin Knots $KNOTS_VER";;
    url\ *)    url=$(printf '%s' "$req" | cut -d' ' -f2); sha=$(printf '%s' "$req" | cut -d' ' -f3); KN_SOURCE=url
               say "  downloading your Knots build: $url";;
    dir\ *)    kd=${req#dir }; [ -x "$kd/bitcoind" ] || kd=$kd/bin
               src_copy "$kd/bitcoind" "$st/bitcoind" && src_copy "$kd/bitcoin-cli" "$st/bitcoin-cli" \
                 || die AP-121 "bitcoind and bitcoin-cli could not be read from $kd$(in_node_home "$kd" && echo " by the node user $U (the folder lies in that user's home, so that user's process reads it)")"
               KN_SOURCE=dir; KN_ORIGIN=$kd; KN_PIN=""; return 0;;
  esac
  KN_ORIGIN=$url
  fetch "$url" "$kt" || die AP-305 "the Knots download failed ($url)"
  if [ "$req" = alphapool ] && [ "$KNOTS_VERIFY" = pin ]; then
    # The build of a start mode that is vouched for by its sha256 alone (a developer build). The release builders have
    # not signed it, so there are no signatures to check: the sha256 pinned in this installer decides, and that is said.
    [ "$(sha_of "$kt")" = "$sha" ] || { rm -f "$kt"; die AP-401 "the Knots download does not match its pinned sha256: refused (nothing was installed)"; }
    say "  this build ($M_LABEL) is NOT signed by the Bitcoin Knots release builders."
    say "  It is pinned in this installer by its sha256, and the download matches it: $sha"
    KN_PIN=$sha
    knots_unpack "$kt" "$st"; rm -f "$kt"
    "$st/bitcoind" -version 2>/dev/null | head -1 | grep -qF "$KNOTS_VER" || die AP-404 "the downloaded bitcoind is not $KNOTS_VER"
    return 0
  fi
  install -d -m 0700 "$st/sig"
  sig_fetch "${url%/*}" "$st/sig"; rc=$?
  if [ $rc -eq 0 ]; then
    if ! knots_sig_check "$st/sig"; then why=AP-406
    elif ! sums_lists "$st/sig/SHA256SUMS" "$(sha_of "$kt")" "${url##*/}"; then why=AP-407
    else signed=1; fi
  elif [ $rc -eq 4 ] && [ "$req" != alphapool ]; then why=none
  else why=AP-308; fi
  if [ $signed -eq 1 ]; then
    say "  builder signatures: the release's SHA256SUMS lists this archive and is signed by $(printf '%s\n' $SIG_SIGNERS | wc -l) pinned Bitcoin Knots builder key(s):"
    for f in $SIG_SIGNERS; do say "    $f"; done
    [ "$SIG_OTHER" -gt 0 ] && say "    ($SIG_OTHER other signature(s), not valid from a pinned key, were ignored)"
  elif [ "$req" = alphapool ] || [ -z "$sha" ]; then
    rm -f "$kt"
    case "$why" in
      AP-406) die AP-406 "the Bitcoin Knots release's SHA256SUMS has no valid signature from a builder key pinned in this installer: refused (nothing was installed)";;
      AP-407) die AP-407 "the release's signed SHA256SUMS does not list the downloaded Knots archive exactly once with its sha256: refused (nothing was installed)";;
      none)   die AP-121 "there is no SHA256SUMS.asc next to $url, so its builder signatures cannot be checked: give its sha256 too (--knots-sha256, from a source you trust)";;
      *)      die AP-308 "the Bitcoin Knots release signatures (SHA256SUMS and SHA256SUMS.asc) could not be downloaded from ${url%/*}: nothing was installed. Run the same command again.";;
    esac
  else       # your own URL with a sha256 you gave: the signatures could not vouch for it, your sha256 decides
    case "$why" in
      AP-406) warn "the SHA256SUMS.asc next to $url has no valid signature from a Bitcoin Knots builder key this installer pins; this build is checked only against the sha256 you gave";;
      AP-407) warn "the signed SHA256SUMS next to $url does not list this archive exactly once with its sha256; this build is checked only against the sha256 you gave";;
      *)      warn "the builder signatures (SHA256SUMS.asc) of $url could not be checked; this build is checked only against the sha256 you gave";;
    esac
  fi
  if [ -n "$sha" ] && [ "$(sha_of "$kt")" != "$sha" ]; then
    rm -f "$kt"
    [ "$req" = alphapool ] && die AP-401 "the Knots download does not match its pinned sha256: refused (nothing was installed)"
    die AP-401 "$url does not match the sha256 you gave: refused (nothing was installed)"
  fi
  KN_PIN=$(sha_of "$kt")
  knots_unpack "$kt" "$st"; rm -f "$kt"; rm -rf "$st/sig"
  if [ "$req" = alphapool ]; then
    "$st/bitcoind" -version 2>/dev/null | head -1 | grep -qF "$KNOTS_VER" || die AP-404 "the downloaded bitcoind is not $KNOTS_VER"
  fi
}
ver_older(){ [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }   # $1 older than $2
installer_is_older(){ ver_older "$AP_VERSION" "$(kv_get "$STATE" software_installer 2>/dev/null || true)"; }
step_knots(){
  step 3 "Bitcoin Knots"
  local req s st
  req=$(kv_get "$REQ" knots || true)
  if [ -z "$req" ]; then
    s=$(kv_get "$STATE" knots_source || true)
    if [ -x /usr/local/bin/bitcoind ] && { [ "${s:-}" != alphapool ] || ! knots_untouched; }; then
      say "  keeping the bitcoind installed on this server (sha256 $(sha_of /usr/local/bin/bitcoind | cut -c1-16)...): your choice"
      say "  (the installer never replaces software you chose; back to AlphaPool's pin: alphapool-node switch knots alphapool)"
      [ "${s:-}" = alphapool ] && kv_set "$STATE" knots_source by-hand
      kv_set "$STATE" knots_installed_sha256 "$(sha_of /usr/local/bin/bitcoind)"
      kv_set "$STATE" knots_cli_installed_sha256 "$(sha_of /usr/local/bin/bitcoin-cli)"
      knots_compat_note
      return 0
    fi
    if [ -x /usr/local/bin/bitcoind ] && [ -x /usr/local/bin/bitcoin-cli ]; then      # AlphaPool's build, as installed
      if [ "$(kv_get "$STATE" knots_pin || true)" = "$KNOTS_SHA256" ]; then say "  Bitcoin Knots $KNOTS_VER is installed (AlphaPool pin)"
      elif installer_is_older; then say "  this installer is older than the one that installed the running Bitcoin Knots: left as it is"
      else UPGRADE_KNOTS=alphapool; say "  this installer pins another Bitcoin Knots build ($KNOTS_VER, $M_LABEL): it replaces the running one at the end of this run (with a way back)"; fi
      return 0
    fi
    req=alphapool
  fi
  work_dir; st=$WORK/stage-knots
  knots_stage "$req" "$st"
  set_install "$st" "" || die AP-503 "bitcoind and bitcoin-cli could not be installed (is the disk full?)"
  kv_del_req knots
  NODE_CHANGED=1
  if [ "$req" != alphapool ]; then knots_compat_note
  elif [ "$KNOTS_VERIFY" = builders ]; then say "  installed Bitcoin Knots $KNOTS_VER (builder signatures and the pinned sha256 checked)"
  else say "  installed Bitcoin Knots $KNOTS_VER (the pinned sha256 checked; this build carries no builder signatures)"; fi
}
knots_compat_note(){
  local v; v=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1)
  say "  bitcoind reports: ${v:-(no version line)}"
  case "$v" in *"$KNOTS_VER"*) ;; *)
    warn "this bitcoind is not the Knots $KNOTS_VER that AlphaPool tests. It must follow the same chain and rules as AlphaPool (Bitcoin Knots of that release line, or later); otherwise your gateway may build jobs AlphaPool cannot use. Back to the tested build: alphapool-node switch knots alphapool";;
  esac
}
kv_del_req(){ [ -e "$REQ" ] && { grep -v -- "^$1=" "$REQ" > "$REQ.tmp"; mv -f "$REQ.tmp" "$REQ"; chmod 0600 "$REQ"; }; return 0; }

# ==== step 4: DATUM gateway ============================================================================================
gw_untouched(){ local rec; rec=$(kv_get "$STATE" gateway_installed_sha256) || return 1; [ -n "$rec" ] && [ "$(sha_u "$GW_BIN")" = "$rec" ]; }
# A gateway archive is never unpacked onto the disk. tar_safe checks its member list; then the one member that is needed
# is read out through a pipe by a tar that runs as the unprivileged node user, into a new file in the root-only scratch
# directory. The archive itself stays where only root can reach it.
gw_member(){   # ARCHIVE NAME_REGEX MAXDEPTH [x]: the first plain-file member whose file name matches (x: it must be executable)
  local l=$WORK/gw.list
  tar -tvf "$1" > "$l" 2>/dev/null || return 1
  awk -v re="$2" -v md="$3" -v needx="${4:-}" 'substr($1, 1, 1) == "-" { n = $NF; p = n; sub(/^\.\//, "", p); d = split(p, a, "/")
      if (d <= md && a[d] ~ re && (needx == "" || substr($1, 4, 1) == "x")) { print n; exit } }' "$l"
}
gw_extract(){   # ARCHIVE MEMBER OUT_FILE
  local z=""              # a tar that reads from a pipe cannot find out the compression itself
  case "$(head -c 6 "$1" | od -An -tx1 | tr -d ' \n')" in 1f8b*) z=-z;; 425a68*) z=-j;; fd377a585a00) z=-J;; 28b52ffd*) z=--zstd;; esac
  # shellcheck disable=SC2086
  new_file "$3" && as_u tar $z -xOf - -- "$2" < "$1" > "$3" && [ -s "$3" ]
}
gw_smoke(){   # [FILE]: its libraries are on this server and it answers --example-conf or --version. Run as the node user, never as root.
  local f=${1:-$GW_BIN} missing
  missing=$(as_u ldd "$f" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
  if [ -n "$missing" ]; then
    if is_dry; then say "  DRY: gateway libraries absent in the test image ($missing): smoke test skipped"; return 0; fi
    die AP-504 "the gateway binary is missing libraries on this server: $missing"
  fi
  if as_u "$f" --example-conf >/dev/null 2>&1 || as_u "$f" --version >/dev/null 2>&1; then return 0; fi
  return 1
}
gw_stage_alphapool(){   # STAGE: AlphaPool's pinned gateway for this Ubuntu release, verified, as STAGE/datum_gateway
  local st=$1 gt m
  work_dir; gt=$WORK/gateway.download
  rm -rf "$st"; install -d -m 0700 "$st"
  sha_ok "$PIN_GW_TAR" && sha_ok "$PIN_GW_BIN" || die AP-405 "AlphaPool's gateway build for this Ubuntu release is not published yet; use Ubuntu 24.04, or install your own build with --gateway-file/--gateway-url/--gateway-git"
  say "  downloading AlphaPool's DATUM gateway release $GW_VER"
  fetch "$PIN_GW_URL" "$gt" || die AP-305 "the gateway download failed (${PIN_GW_URL})"
  [ "$(sha_of "$gt")" = "$PIN_GW_TAR" ] || { rm -f "$gt"; die AP-401 "the gateway download does not match its pinned sha256: refused before unpacking (nothing was installed)"; }
  if tar -tf "$gt" >/dev/null 2>&1; then
    tar_safe "$gt" || die AP-402 "the gateway archive has unsafe members (links, absolute paths or ..): refused"
    m=$(gw_member "$gt" '^datum_gateway$' 3)
    [ -n "$m" ] || die AP-403 "no datum_gateway binary in the gateway archive"
    gw_extract "$gt" "$m" "$st/datum_gateway" || die AP-403 "the gateway archive could not be unpacked"
    m=$(gw_member "$gt" '^BUILDINFO$' 3)
    if [ -n "$m" ]; then gw_extract "$gt" "$m" "$st/BUILDINFO" || rm -f "$st/BUILDINFO"; fi
  else install -m 0755 "$gt" "$st/datum_gateway" || die AP-403 "the gateway download could not be staged"; fi      # the pin is the binary itself
  [ "$(sha_of "$st/datum_gateway")" = "$PIN_GW_BIN" ] || { rm -rf "$st" "$gt"; die AP-401 "the gateway binary does not match its pinned sha256: refused (nothing was installed)"; }
  chmod 0755 "$st/datum_gateway"
  rm -f "$gt"
  GW_SOURCE=alphapool; GW_ORIGIN=$PIN_GW_URL; GW_LABEL="release $GW_VER"
}
step_gateway(){
  step 4 "DATUM gateway"
  local req s gst gt f url sha m repo commit src
  req=$(kv_get "$REQ" gateway || true)
  if [ -z "$req" ]; then
    s=$(kv_get "$STATE" gateway_source || true)
    if has_u -x "$GW_BIN" && { [ "${s:-}" != alphapool ] || ! gw_untouched; }; then
      say "  keeping the gateway installed on this server (sha256 $(sha_u "$GW_BIN" | cut -c1-16)...): your choice"
      say "  (the installer never replaces software you chose; back to AlphaPool's build: alphapool-node switch gateway alphapool)"
      [ "${s:-}" = alphapool ] && kv_set "$STATE" gateway_source by-hand
      kv_set "$STATE" gateway_installed_sha256 "$(sha_u "$GW_BIN")"
      gw_compat_note
      return 0
    fi
    req=alphapool
  fi
  work_dir; gst=$WORK/stage-gw; gt=$WORK/gateway.download
  rm -rf "$gst"; install -d -m 0700 "$gst"
  case "$req" in
    alphapool)
      if [ "$(kv_get "$STATE" gateway_source || true)" = alphapool ] && [ "$(sha_u "$GW_BIN")" = "$PIN_GW_BIN" ] && gw_untouched; then
        say "  AlphaPool gateway release $GW_VER is installed"; return 0
      fi
      if [ -z "$(kv_get "$REQ" gateway || true)" ] && has_u -x "$GW_BIN"; then      # AlphaPool's build, as installed, another pin
        if installer_is_older; then say "  this installer is older than the one that installed the running gateway: left as it is"
        else UPGRADE_GW=alphapool; say "  this installer pins another AlphaPool gateway build (release $GW_VER): it replaces the running one at the end of this run (with a way back)"; fi
        return 0
      fi
      gw_stage_alphapool "$gst";;
    file\ *)
      f=${req#file }
      [ -f "$f" ] || die AP-120 "the gateway file $f is gone"
      src_copy "$f" "$gst/datum_gateway" || die AP-503 "the gateway file $f could not be read$(in_node_home "$f" && echo " by the node user $U (it lies in that user's home, so that user's process reads it)")"
      GW_SOURCE="file"; GW_ORIGIN=$f; GW_LABEL="";;
    url\ *)
      url=$(printf '%s' "$req" | cut -d' ' -f2); sha=$(printf '%s' "$req" | cut -d' ' -f3)
      say "  downloading your gateway build: $url"
      fetch "$url" "$gt" || die AP-305 "the download of $url failed"
      [ "$(sha_of "$gt")" = "$sha" ] || { rm -f "$gt"; die AP-401 "$url does not match the sha256 you gave: refused (nothing was installed)"; }
      if tar -tf "$gt" >/dev/null 2>&1; then
        tar_safe "$gt" || die AP-402 "the gateway archive has unsafe members (links, absolute paths or ..): refused"
        m=$(gw_member "$gt" '^(datum_gateway|ratum-gateway|datum.*gateway.*)$' 3 x)
        [ -n "$m" ] || die AP-403 "no gateway executable (datum_gateway / ratum-gateway) in $url"
        gw_extract "$gt" "$m" "$gst/datum_gateway" || die AP-403 "the gateway archive could not be unpacked"
      else install -m 0755 "$gt" "$gst/datum_gateway" || die AP-503 "the gateway download could not be staged"; fi
      chmod 0755 "$gst/datum_gateway"; rm -f "$gt"
      GW_SOURCE=url; GW_ORIGIN=$url; GW_LABEL="";;
    git\ *)
      repo=$(printf '%s' "$req" | cut -d' ' -f2); commit=$(printf '%s' "$req" | cut -d' ' -f3)
      say "  building a DATUM gateway from $repo at $commit (a few minutes)"
      # shellcheck disable=SC2086
      apt_install $BUILD_PKGS || die AP-501 "the build tools could not be installed"
      src=$HOME_U/src/gw-${commit:0:12}
      as_u mkdir -p "$HOME_U/src"
      GW_SOURCE=git; GW_ORIGIN="$repo@$commit"; GW_LABEL=""
      as_u rm -rf "$src"                         # the node user's folder: its own process cleans it
      if is_dry; then say "  DRY: build skipped"; else
        # --no-tags: the gateway puts `git describe` into its version; with a tag on the commit it would report
        # "<commit>(<tag>)". Without tags it reports the commit, whatever tags the repository has.
        as_u git clone -q --no-tags "$repo" "$src" || die AP-506 "git clone of $repo failed"
        as_u git -C "$src" checkout -q --detach "$commit" || die AP-506 "commit $commit is not in $repo"
        [ "$(as_u git -C "$src" rev-parse HEAD)" = "$commit" ] || die AP-506 "the checkout is not commit $commit"
        as_u bash -c "cd '$src' && cmake -S . -B . >/dev/null && make -j\$(nproc) >/dev/null" || die AP-506 "the gateway did not build (see $src)"
        has_u -x "$src/datum_gateway" || die AP-506 "the build produced no datum_gateway"
        # the build folder belongs to the node user: a process of that user reads the result into root's scratch directory
        as_u cat "$src/datum_gateway" > "$gst/datum_gateway" && [ -s "$gst/datum_gateway" ] \
          && chmod 0755 "$gst/datum_gateway" || die AP-506 "the built datum_gateway could not be staged"
      fi;;
  esac
  if [ -f "$gst/datum_gateway" ]; then
    set_install "" "$gst" || die AP-503 "could not install the gateway binary (is the disk full?)"
  else kv_set "$STATE" gateway_source "$GW_SOURCE"; kv_set "$STATE" gateway_origin "$GW_ORIGIN"; fi     # test mode: nothing was built
  [ "$req" != alphapool ] || gw_smoke "$GW_BIN" || die AP-504 "AlphaPool's gateway binary does not run on this server"
  kv_set "$STATE" gateway_installed_sha256 "$(sha_u "$GW_BIN")"
  kv_del_req gateway
  GW_CHANGED=1
  if [ "$req" != alphapool ]; then gw_smoke "$GW_BIN" || warn "the gateway binary did not answer --example-conf or --version; it may not run on this server"; gw_compat_note; fi
  say "  gateway binary sha256 $(sha_u "$GW_BIN")"
}
gw_compat_note(){
  [ "$(sha_u "$GW_BIN")" = "$PIN_GW_BIN" ] && return 0
  warn "you run a DATUM gateway build AlphaPool has not tested (sha256 $(sha_u "$GW_BIN" | cut -c1-16)...). AlphaPool tests its own build (release $GW_VER); other builds may handle AlphaPool's payout list differently. If mining does not work as expected: alphapool-node switch gateway alphapool"
}

# ==== the validated start (assumeutxo) =================================================================================
# The node loads a UTXO snapshot: the set of all unspent coins at one block. Bitcoin Knots accepts a snapshot only
# for a block that is compiled into it, and only if the snapshot's content has the hash that is compiled in as well.
# From there the node validates every later block itself, and in the background the whole history before the snapshot.
#   step 5  which snapshot (the table, by the installed Knots version); the build is asked whether it knows it;
#           download (resumable, waits for a download slot), sha256, the file's own header
#   step 9  wait for the block headers; hand the file to the node; loadtxoutset; then the catch-up to the chain tip
# A journal (/etc/alphapool/validated-start.journal) is there from step 5 until the snapshot is loaded. While it is
# there the install is not complete: a re-run, and the resume unit after a reboot, continue it. If anything fails, the
# node is STOPPED: a node left running without its snapshot would sync the whole chain from the network, for days,
# without telling anyone.
UX_BUILD=""; UX_HEIGHT=""; UX_BASE=""; UX_FILE=""; UX_BYTES=""; UX_SHA=""; UX_URL=""; UX_FROM=""; UX_IH=""; UX_TURL=""
knots_version(){ /usr/local/bin/bitcoind -version 2>/dev/null | head -1 | sed -E 's/^.* version v?//'; }
utxo_line_ok(){ [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && sha_ok "$2" && [[ $3 =~ ^[A-Za-z0-9._-]+$ ]] && [[ $4 =~ ^[1-9][0-9]{0,14}$ ]] && sha_ok "$5" && url_ok "$6"; }
utxo_extra_ok(){ { [ -z "${1:-}" ] || [[ $1 =~ ^[0-9a-f]{40}$ ]]; } && { [ -z "${2:-}" ] || url_ok "$2"; }; }   # columns 7 and 8, both optional
# utxo_pick HOW -> UX_* (1 = there is no snapshot). HOW is "mode" when the node runs, or gets in this run, the build of
# its start mode, and "ask" for a build of your own. In this order:
#   1. the snapshot you named (--utxo-url with its three values);
#   2. --utxo-height alone: the table's line with that height;
#   3. mode: the table's line with the start mode's height;
#   4. ask: the installed build is asked about each snapshot of the table, the newest first, and the first one it
#      knows is taken (UX_ASKED=yes). If the build cannot be asked at all, the newest one is taken and the node itself
#      decides when it loads it (UX_ASKED=no).
UX_ASKED=""
utxo_pick(){
  local how=${1:-mode} want h b f n k u rc first="" heights=""
  UX_HEIGHT=""; UX_BASE=""; UX_FILE=""; UX_BYTES=""; UX_SHA=""; UX_URL=""; UX_FROM=""; UX_ASKED=""; UX_IH=""; UX_TURL=""
  if [ -n "$UTXO_URL" ]; then
    UX_HEIGHT=$UTXO_HEIGHT; UX_FILE=utxo-$UTXO_HEIGHT.dat; UX_BYTES=$UTXO_BYTES; UX_SHA=$UTXO_SHA256; UX_URL=$UTXO_URL; UX_FROM=yours
    return 0
  fi
  want=$UTXO_HEIGHT
  [ -n "$want" ] || [ "$how" != mode ] || want=$M_HEIGHT
  if [ -n "$want" ]; then
    while read -r h b f n k u ih tu _; do
      [ "$h" = "$want" ] && utxo_line_ok "$h" "$b" "$f" "$n" "$k" "$u" || continue
      UX_HEIGHT=$h; UX_BASE=$b; UX_FILE=$f; UX_BYTES=$n; UX_SHA=$k; UX_URL=$u; UX_FROM=table
      utxo_extra_ok "${ih:-}" "${tu:-}" && { UX_IH=${ih:-}; UX_TURL=${tu:-}; }
      return 0
    done < <(utxo_table)
    return 1
  fi
  while read -r h b f n k u ih tu _; do
    utxo_line_ok "$h" "$b" "$f" "$n" "$k" "$u" || continue
    knots_knows /usr/local/bin "$b"; rc=$?
    [ -n "$KN_HEIGHTS" ] && heights=$KN_HEIGHTS
    if [ $rc -eq 0 ] || { [ $rc -eq 2 ] && [ -z "$first" ]; }; then
      UX_HEIGHT=$h; UX_BASE=$b; UX_FILE=$f; UX_BYTES=$n; UX_SHA=$k; UX_URL=$u; UX_FROM=table
      utxo_extra_ok "${ih:-}" "${tu:-}" && { UX_IH=${ih:-}; UX_TURL=${tu:-}; }
      [ $rc -eq 0 ] && { UX_ASKED=yes; return 0; }
      first=$h; UX_ASKED=no
    fi
  done < <(utxo_table | awk '$1 !~ /^#/ && NF >= 6' | sort -k1,1nr | awk '!seen[$2]++')
  KN_HEIGHTS=$heights
  [ "$UX_ASKED" = no ] && return 0           # (a line that could be asked and was refused never sets UX_*: see the order above)
  UX_HEIGHT=""; UX_URL=""
  return 1
}
uj_pending(){ [ -f "$UJ" ] && [ ! -L "$UJ" ]; }
# The handover directory is used only as a directory of root's that nobody else may write (fast_load makes or checks
# it). Whatever else has that name is left alone: nothing in it is looked at, moved or removed.
hand_ok(){ local o; [ -d "$HAND" ] && [ ! -L "$HAND" ] && o=$(stat -c '%u %a' -- "$HAND" 2>/dev/null) && [ "${o%% *}" = 0 ] && (( (8#${o##* } & 8#022) == 0 )); }
uj_drop(){   # you chose another way: an unfinished validated start is dropped, with the snapshot file it had downloaded
  network_restore
  local f; f=$(kv_get "$UJ" file 2>/dev/null || true)
  if [[ $f =~ ^[A-Za-z0-9._-]+$ ]]; then rm -f -- "${DL:?}/${f:?}" "${DL:?}/${f:?}.aria2"; hand_ok && rm -f -- "${HAND:?}/${f:?}"; fi
  rm -f "$UJ"
}
uj_write(){
  ( umask 077; printf 'format=1\nstarted=%s\nbuild=%s\nheight=%s\nbase=%s\nfile=%s\nbytes=%s\nsha256=%s\nurl=%s\nfrom=%s\ninfohash=%s\ntorrent=%s\n' \
      "$(date -u +%FT%TZ)" "$UX_BUILD" "$UX_HEIGHT" "$UX_BASE" "$UX_FILE" "$UX_BYTES" "$UX_SHA" "$UX_URL" "$UX_FROM" "$UX_IH" "$UX_TURL" > "$UJ.new" ) \
    && mv -f "$UJ.new" "$UJ" || die AP-503 "the journal of the validated start could not be written (is the disk full?)"
  sync "$UJ" "$ETC" 2>/dev/null; return 0
}
uj_load(){
  UX_BUILD=$(kv_get "$UJ" build || true); UX_HEIGHT=$(kv_get "$UJ" height || true); UX_BASE=$(kv_get "$UJ" base || true)
  UX_FILE=$(kv_get "$UJ" file || true); UX_BYTES=$(kv_get "$UJ" bytes || true); UX_SHA=$(kv_get "$UJ" sha256 || true)
  UX_URL=$(kv_get "$UJ" url || true); UX_FROM=$(kv_get "$UJ" from || true)
  UX_IH=$(kv_get "$UJ" infohash || true); UX_TURL=$(kv_get "$UJ" torrent || true)
  utxo_extra_ok "$UX_IH" "$UX_TURL" || { UX_IH=""; UX_TURL=""; }
  [[ $UX_HEIGHT =~ ^[1-9][0-9]{0,8}$ ]] && [[ $UX_FILE =~ ^[A-Za-z0-9._-]+$ ]] && [[ $UX_BYTES =~ ^[1-9][0-9]{0,14}$ ]] && sha_ok "$UX_SHA" && url_ok "$UX_URL" \
    || die AP-503 "the journal of the validated start ($UJ) is damaged. Remove it and run the same command again."
}
utxo_early(){   # before anything is installed: the snapshot, if it can be known already (UX_URL stays empty if not)
  UX_URL=""
  if uj_pending; then uj_load; return 0; fi
  case "$KNOTS_CHOICE" in
    alphapool) utxo_pick mode || die AP-122 "this installer has no UTXO snapshot for the start mode '$M_NAME' (Bitcoin Knots $KNOTS_VER${UTXO_HEIGHT:+, height $UTXO_HEIGHT}). Without one the validated start is not possible; --sync network syncs everything from the network (days).";;
    *)         [ -z "$UTXO_URL" ] || utxo_pick ask;;              # a build of your own: which snapshot it knows is asked in step 5, when it is installed
  esac
  return 0
}
# knots_knows BINDIR BLOCK_HASH: can the bitcoind in BINDIR start from the UTXO snapshot of that block?
#   0 yes    1 no (KN_HEIGHTS = the heights it knows)    2 it could not be found out
# The build is asked itself, on an empty scratch folder of the node user's, with no network: it is given a 51-byte
# snapshot header that names the block. A build that does not know the block says so at once and lists the heights it
# knows; a build that knows it asks for the block headers first. Nothing of the real node is touched and no snapshot
# is loaded.
KN_HEIGHTS=""
knots_knows(){
  local bin=$1 base=$2 d port="" out="" i rp
  KN_HEIGHTS=""
  sha_ok "$base" && [ -x "$bin/bitcoind" ] && [ -x "$bin/bitcoin-cli" ] || return 2
  d=$(as_u mktemp -d "$HOME_U/.alphapool-ask.XXXXXXXX" 2>/dev/null) || return 2
  { printf 'utxo\xff\x02\x00'; hex_to_bin "$NODE_NET_MAGIC"; hex_to_bin "$(hex_rev "$base")"; printf '\0\0\0\0\0\0\0\0'; } \
    | as_u sh -c 'cat > "$1/ask.dat"' _ "$d" || { as_u rm -rf "$d"; return 2; }
  if is_dry && [ "${AP_DRY_ASK:-fake}" != real ]; then
    out=$(as_u timeout 20 "$bin/bitcoin-cli" -datadir="$d" loadtxoutset "$d/ask.dat" 2>&1)
  else
    for i in 1 2 3 4 5 6; do
      port=$(( 20000 + RANDOM % 20000 ))
      ss -Htln "sport = :$port" 2>/dev/null | grep -q . || break
    done
    as_u "$bin/bitcoind" -datadir="$d" -chain="$NODE_CHAIN" -server=1 -listen=0 -connect=0 -dnsseed=0 -fixedseeds=0 \
      -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 -rpcport="$port" -dbcache=4 -disablewallet=1 -daemon=0 >/dev/null 2>&1 &
    rp=$!
    for i in $(seq 1 60); do
      as_u timeout 10 "$bin/bitcoin-cli" -datadir="$d" -chain="$NODE_CHAIN" -rpcport="$port" getblockcount >/dev/null 2>&1 && break
      kill -0 "$rp" 2>/dev/null || break
      sleep 1
    done
    out=$(as_u timeout 30 "$bin/bitcoin-cli" -datadir="$d" -chain="$NODE_CHAIN" -rpcport="$port" loadtxoutset "$d/ask.dat" 2>&1)
    as_u timeout 10 "$bin/bitcoin-cli" -datadir="$d" -chain="$NODE_CHAIN" -rpcport="$port" stop >/dev/null 2>&1
    for i in $(seq 1 30); do kill -0 "$rp" 2>/dev/null || break; sleep 1; done
    if kill -0 "$rp" 2>/dev/null; then pkill -KILL -u "$U" -f -- "-datadir=$d" 2>/dev/null; kill -KILL "$rp" 2>/dev/null; fi
    wait "$rp" 2>/dev/null
  fi
  as_u rm -rf "$d"
  case "$out" in
    *"not recognized"*) KN_HEIGHTS=$(printf '%s' "$out" | tr '\n' ' ' | sed -n 's/.*snapshot heights are available: \([0-9, ]*[0-9]\).*/\1/p'); return 1;;
    *"must appear in the headers chain"*) return 0;;
  esac
  return 2
}
# A node that started from a UTXO snapshot keeps that snapshot's chain state in a folder of its own until its history
# check has finished. A Bitcoin Knots build that does not know the snapshot's block refuses to start on it. So before
# another build is put in place on such a node, that build is asked.
SG_BASE=""
sg_height(){   # the height of the snapshot block SG_BASE, if this installer knows it: from its own record, or from its table
  local h; h=$(kv_get "$STATE" chain_start_height 2>/dev/null || true)
  if [ -n "$h" ] && [ "$(kv_get "$STATE" chain_start_base 2>/dev/null || true)" = "$SG_BASE" ]; then printf '%s' "$h"; return 0; fi
  utxo_table | awk -v b="$SG_BASE" '$2 == b {print $1; exit}'
}
sg_block(){ local h; h=$(sg_height); if [ -n "$h" ]; then printf '%s (%s)' "$h" "$SG_BASE"; else printf '%s' "$SG_BASE"; fi; }   # for a message
# snapshot_guard BINDIR [pinned]: 1 = that build cannot run this node as it is (SG_BASE, KN_HEIGHTS).
# The build itself is asked. If it cannot be asked and it is the build of a start mode ("pinned"), the installer's own
# list of the heights that build knows decides. A build of your own that cannot be asked is not refused here: if the
# node then does not start on it, the upgrade puts the previous build back and says why (AP-414).
snapshot_guard(){
  local raw rc h
  raw=$(as_u od -An -v -tx1 -N32 "$CDIR/chainstate_snapshot/base_blockhash" 2>/dev/null | tr -d ' \n')
  [[ $raw =~ ^[0-9a-f]{64}$ ]] || return 0
  SG_BASE=$(hex_rev "$raw")
  knots_knows "$1" "$SG_BASE"; rc=$?
  [ $rc -ne 1 ] || return 1
  [ $rc -ne 0 ] || return 0
  [ "${2:-}" = pinned ] || return 0
  h=$(sg_height); [ -n "$h" ] || return 0
  [[ " $M_KNOWS " == *" $h "* ]] && return 0
  KN_HEIGHTS=${M_KNOWS// /, }
  return 1
}
# The other half, for a build that could not be judged before it was started: a node that started from a snapshot and
# has not finished its history check does not start under a build that does not know the snapshot's block. Bitcoin
# Knots says so in its log ("Assumeutxo data not found for the given blockhash") and stops.
node_log_size(){ local n; n=$(as_u stat -c %s "$CDIR/debug.log" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
node_refused_snapshot(){   # SIZE [SINCE]: the node said it, in what its log got after it had that size (or, failing that, in the service's journal since that time)
  as_u tail -c +"$(( ${1:-0} + 1 ))" "$CDIR/debug.log" 2>/dev/null | tail -c 200000 | grep -aq 'Assumeutxo data not found for the given blockhash' && return 0
  is_dry && return 1
  [[ ${2:-} =~ ^[0-9]+$ ]] || return 1
  journalctl -u knots-node.service --since "@$2" --no-pager 2>/dev/null | tail -n 400 | grep -aq 'Assumeutxo data not found for the given blockhash'
}
REFUSED_WHY="the new Bitcoin Knots cannot run this node yet: the node started from a UTXO snapshot and has not finished checking the history before it, and the new build does not know that snapshot's block (Bitcoin Knots said: Assumeutxo data not found for the given blockhash). Upgrade when the history check is complete: alphapool-node status shows it"
utxo_ask_build(){   # the installed Bitcoin Knots is asked whether it knows the snapshot in UX_* (once per build)
  local sha
  sha=$(sha_of /usr/local/bin/bitcoind)
  [ "$(kv_get "$UJ" knows || true)" = "$sha" ] && return 0
  knots_knows /usr/local/bin "$UX_BASE"
  case $? in
    0) kv_set "$UJ" knows "$sha"; say "  Bitcoin Knots $(knots_version) knows this snapshot (it was asked)";;
    1) rm -f "$DL/$UX_FILE" "$DL/$UX_FILE.aria2" "$UJ"
       die AP-411 "the Bitcoin Knots build on this server ($(knots_version)) cannot start from the UTXO snapshot of block $UX_HEIGHT: that block is not compiled into it${KN_HEIGHTS:+ (it knows the heights $KN_HEIGHTS)}. Use AlphaPool's tested build (--knots alphapool), or name a snapshot your build knows (--utxo-url, --utxo-sha256, --utxo-bytes, --utxo-height), or sync from the network (--sync network: days).";;
    *) say "  (this build could not be asked now whether it knows the snapshot; the node says so itself when it loads it)";;
  esac
  return 0
}
utxo_check_header(){   # FILE: it is a UTXO snapshot, of this chain, and of the block the installer expects
  local hdr base
  hdr=$(head -c 51 "$1" | od -An -v -tx1 | tr -d ' \n')
  [ "${hdr:0:10}" = 7574786fff ] || { rm -f "$1"; die AP-412 "the downloaded file is not a UTXO snapshot (it does not begin like one): it was deleted"; }
  [ "${hdr:14:8}" = "$NODE_NET_MAGIC" ] || { rm -f "$1"; die AP-412 "the UTXO snapshot is for another network than this node's: it was deleted"; }
  base=$(hex_rev "${hdr:22:64}")
  if [ -n "$UX_BASE" ] && [ "$base" != "$UX_BASE" ]; then
    rm -f "$1"; die AP-412 "the UTXO snapshot names block $base as its base, not the block this installer expects at height $UX_HEIGHT ($UX_BASE): it was deleted"
  fi
  if [ -z "$UX_BASE" ]; then UX_BASE=$base; kv_set "$UJ" base "$base"; fi
  return 0
}
utxo_peek(){   # a snapshot you named: its first 51 bytes say which block it is of (UX_BASE). Not possible on every server: then later.
  local f hdr
  work_dir; f=$WORK/utxo.head
  if is_dry && [ "${AP_DRY_REAL_DOWNLOAD:-0}" != 1 ]; then
    [ -n "${AP_DRY_FIXTURES:-}" ] && head -c 51 "$AP_DRY_FIXTURES/${UX_URL##*/}" > "$f" 2>/dev/null || return 0
  else
    new_file "$f" && curl -fsS -r 0-50 --max-filesize 100 --connect-timeout 20 --max-time 60 -o "$f" "$UX_URL" 2>/dev/null || return 0
  fi
  [ "$(stat -c %s "$f" 2>/dev/null)" = 51 ] || return 0
  hdr=$(od -An -v -tx1 "$f" | tr -d ' \n')
  [ "${hdr:0:10}" = 7574786fff ] && [ "${hdr:14:8}" = "$NODE_NET_MAGIC" ] || return 0
  UX_BASE=$(hex_rev "${hdr:22:64}"); kv_set "$UJ" base "$UX_BASE"
  return 0
}
fast_take_back(){   # FILE: the snapshot file comes back from the handover directory into the work area (both are root's)
  local hf=$HAND/${1##*/}
  hand_ok || return 0
  [ -e "$hf" ] || [ -L "$hf" ] || return 0
  if [ -e "$1" ] || ! plain_own "$hf"; then rm -f -- "$hf"; return 0; fi
  chgrp 0 -- "$hf"; chmod 0600 -- "$hf"; mv -T -f -- "$hf" "$1"
  return 0
}
catchup_about(){   # how long the node validates after its snapshot, said the same way everywhere: the start mode's duration
  local h=${UX_HEIGHT:-$(kv_get "$STATE" chain_start_height 2>/dev/null || true)}
  if [ "${UX_FROM:-table}" != yours ] && [ "$h" = "$M_HEIGHT" ]; then printf '%s on a small server' "$M_ABOUT"
  else printf 'how long depends on how far back your snapshot is'; fi
}
utxo_file_ready(){   # the snapshot file is in the work area, complete, with the right sha256 and a header that fits. Can be run again.
  local f=$DL/$UX_FILE got=0 need_dl frc
  work_dir
  fast_take_back "$f"
  if [ "$(kv_get "$UJ" verified || true)" = "$UX_SHA" ] && plain_own "$f" && [ ! -e "$f.aria2" ] && [ "$(stat -c %s "$f")" = "$UX_BYTES" ]; then
    say "  the UTXO snapshot is downloaded and checked"; return 0
  fi
  plain_own "$f" && got=$(on_disk "$f")
  plain_own "$f.bt" && got=$(( got + $(on_disk "$f.bt") ))
  need_dl=$(( UX_BYTES - got )); [ "$need_dl" -ge 0 ] || need_dl=0
  space_for "$need_dl" $(( 30 * 1000**3 )) || die AP-206 "only $(gb "$SP_AVAIL") GB free$SP_WHERE; the validated start needs $(gb "$SP_NEED") GB (the snapshot file, the chain state it becomes, and room for blocks)"
  if utxo_torrent_on; then say_t "  downloading the UTXO snapshot ($(gb "$UX_BYTES") GB): BitTorrent first, ${UX_URL#https://} as the fallback"
  else say_t "  downloading the UTXO snapshot ($(gb "$UX_BYTES") GB) from ${UX_URL#https://}"; fi
  rstate downloading "$got" "$UX_BYTES"
  frc=1
  if utxo_torrent_on; then utxo_torrent_download "$f" && frc=0; fi
  if [ $frc -ne 0 ]; then
    ! utxo_torrent_on || say "  downloading over https from ${UX_URL#https://}"
    fetch_big "$UX_URL" "$f" "$UX_BYTES" "UTXO snapshot"; frc=$?
  fi
  [ $frc -eq 3 ] && die AP-307 "the download server had no free download slot for $(( SLOT_WAITED / 3600 )) hours. Run the same command again later: the download resumes where it stopped."
  [ $frc -eq 0 ] || die AP-306 "the UTXO snapshot download did not finish (network trouble). Run the same command again: the download resumes where it stopped."
  say_t "  downloaded; checking the file's sha256 (about a minute)"
  rstate verifying "$UX_BYTES" "$UX_BYTES"; status_set "step $STEP_N/$TOTAL_STEPS: checking the UTXO snapshot"
  if [ "$(sha_of "$f")" != "$UX_SHA" ]; then
    rm -f "$f" "$f.aria2"; rstate failed 0 "$UX_BYTES"
    die AP-401 "the downloaded UTXO snapshot does not match its sha256 (a damaged download): it was deleted. Run the same command again to download it again."
  fi
  utxo_check_header "$f"
  kv_set "$UJ" verified "$UX_SHA"
  say_t "  sha256 matches$([ "$UX_FROM" = table ] && echo ' the pin'); the file is the snapshot of block $(sep "$UX_HEIGHT")"
  utxo_seed_start "$f"
}
# ---- the snapshot over BitTorrent -----------------------------------------------------------------------------------------
# Other installing nodes and the seeders share the load, and a busy https server costs nothing. The pinned info hash is
# the check: aria2 takes no piece whose hash is not in the metadata the info hash names, and the sha256 check follows
# as before. The https download stays the fallback: no download speed for 15 minutes ends the torrent attempt.
utxo_torrent_on(){ [ "$UTXO_TORRENT" = on ] && [ -n "$UX_IH" ] && ! is_dry; }
# utxo_torrent_download FILE: BitTorrent (aria2) into FILE. The source is the pinned .torrent file (fetched, and used only
# if its info hash is the pinned one) or the magnet link made of the pinned info hash and the pinned trackers. The pieces
# land in FILE.bt (a torrent's partial file is sparse: https must never "resume" it); a re-run resumes it with aria2
# re-checking the pieces on disk; giving up deletes it. The metadata is saved next to it (<info hash>.torrent) for the
# seeding. An https download that was started earlier (FILE.aria2) is left to https. 0 = complete, 1 = give up.
utxo_torrent_download(){
  local f=$1 dir name part src="" t rc stop=${AP_TORRENT_STOP_S:-900} tr="" x
  dir=$(dirname "$f"); name=$(basename "$f").bt; part=$f.bt
  [ ! -e "$f.aria2" ] || return 1
  t=$dir/$UX_IH.torrent
  for x in $UTXO_TRACKERS; do tr="$tr&tr=$(printf '%s' "$x" | sed 's/:/%3A/g; s#/#%2F#g')"; done
  if [ -n "$UX_TURL" ]; then
    if new_file "$t" && curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 --max-filesize 4000000 -o "$t" "$UX_TURL" 2>/dev/null \
       && [ "$(aria2c -S "$t" 2>/dev/null | sed -n 's/^Info Hash: *//p' | head -1)" = "$UX_IH" ]; then src=$t
    else rm -f -- "$t"; say "  the .torrent file could not be fetched, or it is not the pinned one: the magnet link is used instead"; fi
  fi
  [ -n "$src" ] || src="magnet:?xt=urn:btih:$UX_IH&dn=$UX_FILE$tr"
  say "  BitTorrent: other installing nodes and the seeders share the load (no download speed for $(( stop / 60 )) min ends this attempt)"
  progress_loop "$part" "$UX_BYTES" "UTXO snapshot (torrent)" & BG_PID=$!
  aria2c -q -c -d "$dir" --index-out="1=$name" --check-integrity=true --file-allocation=none --seed-time=0 \
    --bt-save-metadata=true --bt-stop-timeout="$stop" --bt-max-peers=60 --listen-port=6881-6889 --dht-listen-port=6881-6889 \
    --enable-dht=true --bt-enable-lpd=false --bt-tracker-connect-timeout=20 --bt-tracker-timeout=30 \
    --max-tries=0 --retry-wait=10 --connect-timeout=20 --timeout=60 --console-log-level=error --summary-interval=0 "$src"; rc=$?
  kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""
  if [ ! -e "$part" ] && [ -e "$f.aria2" ]; then rm -f -- "$f" "$f.aria2"; fi      # aria2 ignored --index-out: no sparse file for https
  if [ $rc -ne 0 ]; then say "  the torrent download stopped (aria2 exit $rc)"; rm -f -- "$part" "$part.aria2"; return 1; fi
  [ "$(stat -c %s "$part" 2>/dev/null)" = "$UX_BYTES" ] || { rm -f -- "$part" "$part.aria2"; return 1; }
  rm -f -- "$part.aria2"; mv -T -f -- "$part" "$f"
  return 0
}
# utxo_seed_start FILE: seed the checked snapshot to other installing nodes for a while (at most UTXO_SEED_MINUTES, or
# share ratio 2) as the transient service alphapool-snapshot-seed. The seeder keeps FILE open, so the node's load, which
# moves and then deletes the file, does not stop it; the space is freed when it ends. If ufw is on, TCP 6881 is allowed
# meanwhile and removed after. Off: --no-seed. Stop early: systemctl stop alphapool-snapshot-seed
utxo_seed_start(){
  local f=$1 t sd=$VAR/seed
  [ "$UTXO_SEED" = on ] && utxo_torrent_on || return 0
  t=$(dirname "$f")/$UX_IH.torrent
  [ -s "$t" ] || return 0                                    # (no metadata was saved: nothing to seed from)
  priv_dir "$sd" || { warn "$sd is there already, but not as a directory of root's alone: the snapshot is not seeded"; return 0; }
  cp -f -- "$t" "$sd/$UX_IH.torrent" || return 0
  cat > "$LIB/snapshot-seed.new" <<'EOS'
#!/bin/bash
# Seeds the UTXO snapshot this node downloaded to other installing nodes (BitTorrent), for at most MINUTES or until
# share ratio 2. Started by the installer as the transient service alphapool-snapshot-seed; stop: systemctl stop alphapool-snapshot-seed
set -u
f=$1 t=$2 mins=${3:-120} rule=0
if ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; then
  ufw allow 6881:6889/tcp comment "AlphaPool node: snapshot seeding (temporary)" >/dev/null 2>&1 && rule=1
fi
finish(){ [ "$rule" = 1 ] && ufw delete allow 6881:6889/tcp >/dev/null 2>&1; rm -f -- "$t"; }
trap finish EXIT
# aria2 gives up when it cannot bind its listen port: it gets a range and takes the first free one
aria2c -q -d "$(dirname "$f")" --index-out="1=$(basename "$f")" --check-integrity=true --file-allocation=none \
  --seed-ratio=2.0 --seed-time="$mins" --listen-port=6881-6889 --dht-listen-port=6881-6889 --enable-dht=true --bt-enable-lpd=false \
  --bt-max-peers=80 --console-log-level=error --summary-interval=0 "$t"
EOS
  chmod 0755 "$LIB/snapshot-seed.new" && mv -f "$LIB/snapshot-seed.new" "$LIB/snapshot-seed"
  systemctl stop alphapool-snapshot-seed.service >/dev/null 2>&1
  if systemd-run --unit=alphapool-snapshot-seed --description="Seed the UTXO snapshot to other installing nodes (temporary)" --collect --quiet \
       "$LIB/snapshot-seed" "$f" "$sd/$UX_IH.torrent" "$UTXO_SEED_MINUTES"; then
    say "  seeding the snapshot to other installing nodes for up to $UTXO_SEED_MINUTES min (off: --no-seed; stop: systemctl stop alphapool-snapshot-seed)"
  else warn "the seeding could not be started (systemd-run)"; rm -f -- "$sd/$UX_IH.torrent"; fi
}
utxo_prepare(){   # step 5 of a validated start
  local build how=ask
  FAST_OPEN=1
  # Which build will the node run? Its start mode's (installed as pinned, or replacing the installed one later in this
  # run): then the mode says which snapshot. Or a build of your own: then that build is asked.
  if [ -n "$UPGRADE_KNOTS" ] || { [ "$(kv_get "$STATE" knots_source || true)" = alphapool ] && [ "$(kv_get "$STATE" knots_pin || true)" = "$KNOTS_SHA256" ]; }; then
    how=mode; build=$KNOTS_SHA256
  else build=$(sha_of /usr/local/bin/bitcoind); fi
  if uj_pending; then uj_load; fi
  if ! uj_pending || [ "$UX_BUILD" != "$build" ]; then
    utxo_pick "$how" \
      || die AP-122 "this installer has no UTXO snapshot that the Bitcoin Knots build on this server can start from (version $(knots_version)${UTXO_HEIGHT:+, asked for height $UTXO_HEIGHT}${KN_HEIGHTS:+; the build knows the heights $KN_HEIGHTS}), so the validated start is not possible with it. Use AlphaPool's tested build (--knots alphapool), or name a snapshot your build knows (--utxo-url, --utxo-sha256, --utxo-bytes, --utxo-height), or sync from the network (--sync network: days)."
    UX_BUILD=$build
    uj_write
    case "$UX_ASKED" in
      yes) kv_set "$UJ" knows "$(sha_of /usr/local/bin/bitcoind)"
           say "  this Bitcoin Knots build ($(knots_version)) is not one of the installer's start modes; it was asked, and it knows the snapshot of block $(sep "$UX_HEIGHT")";;
      no)  say "  this Bitcoin Knots build ($(knots_version)) is not one of the installer's start modes, and it could not be asked: the newest snapshot is taken, and the node decides when it loads it";;
    esac
  fi
  case "$UX_FROM:$how" in
    yours:*)    say "  the validated start: the UTXO snapshot of block $(sep "$UX_HEIGHT"), the one you named";;
    table:mode) say "  the validated start: the UTXO snapshot of block $(sep "$UX_HEIGHT"), the one compiled into Bitcoin Knots $KNOTS_VER ($M_LABEL)";;
    *)          say "  the validated start: the UTXO snapshot of block $(sep "$UX_HEIGHT")";;
  esac
  if as_u test -f "$CDIR/chainstate_snapshot/base_blockhash" 2>/dev/null; then
    say "  the node has loaded it already"; return 0
  fi
  [ -n "$UX_BASE" ] || utxo_peek                                             # a snapshot you named: which block is it of?
  if [ -n "$UX_BASE" ] && [ -z "$UPGRADE_KNOTS" ]; then utxo_ask_build; fi      # before 9.6 GB are downloaded
  utxo_file_ready
  say "  it is loaded in step 9, when the node is running and has the block headers"
}
fast_abort(){   # a validated start that failed: the node is stopped, and stays stopped until the installer runs again
  FAST_OPEN=0
  fast_take_back "$DL/${UX_FILE:-utxo.dat}"
  run systemctl disable --now alphapool-gateway-start.service knots-node.service >/dev/null 2>&1
  return 0
}
snapshot_active(){ cli getchainstates 2>/dev/null | jq -e '[.chainstates[] | select(.snapshot_blockhash != null)] | length > 0' >/dev/null 2>&1; }
HEADERS_WAIT=$(num_or "${AP_HEADERS_WAIT:-}" 7200)
NOPEERS_WAIT=$(num_or "${AP_NOPEERS_WAIT:-}" 900)
STALL_S=$(num_or "${AP_STALL_S:-}" 3600)
headers_progress(){   # "first pass of two, 47%": from the node's own log (its header count stays 0 during the first pass)
  local l p
  l=$(as_u tail -c 40000 "$CDIR/debug.log" 2>/dev/null | grep -a 'ynchronizing blockheaders, height' | tail -1)
  p=$(printf '%s' "$l" | sed -n 's/.*(~\([0-9]*\)[0-9.]*%).*/\1/p')
  [ -n "$p" ] || return 0
  case "$l" in *Pre-synchronizing*) printf 'first pass of two, %s%%' "$p";; *) printf 'second pass of two, %s%%' "$p";; esac
}
fast_wait_headers(){   # the node must have the header of the snapshot's block before it takes the snapshot
  local t0 now last=0 peers none=0 line h nap=10
  is_dry && nap=1
  t0=$(date +%s)
  say "  waiting for the block headers from the network (the node needs the header of block $(sep "$UX_HEIGHT") first)"
  while :; do
    h=$(cli getblockheader "$UX_BASE" 2>/dev/null | jq -r '.height // empty' 2>/dev/null)
    if [ -n "$h" ]; then
      [ "$h" = "$UX_HEIGHT" ] || die AP-412 "block $UX_BASE is at height $h in this node's chain, not at $UX_HEIGHT: the snapshot does not belong to this chain"
      say_t "  the block headers are there ($(dur $(( $(date +%s) - t0 ))))"; return 0
    fi
    now=$(date +%s); peers=$(cli getconnectioncount 2>/dev/null); [[ $peers =~ ^[0-9]+$ ]] || peers=0
    if [ "$peers" -gt 0 ]; then none=0; elif [ "$none" = 0 ]; then none=$now; fi
    if [ $(( now - last )) -ge 60 ]; then
      line=$(headers_progress)
      say "  block headers: ${line:-waiting for the first ones}, $peers peers"
      status_set "step $STEP_N/$TOTAL_STEPS: getting the block headers (${line:-starting}, $peers peers)"
      last=$now
    fi
    if [ "$none" != 0 ] && [ $(( now - none )) -ge "$NOPEERS_WAIT" ]; then
      die AP-309 "the node has found no other nodes (peers) for $(( NOPEERS_WAIT / 60 )) minutes, so it gets no block headers. Allow outgoing TCP 8333 in your provider's firewall, then run the same command again."
    fi
    [ $(( now - t0 )) -lt "$HEADERS_WAIT" ] || die AP-309 "the block headers did not arrive within $(( HEADERS_WAIT / 60 )) minutes ($peers peers). Check the server's network, then run the same command again."
    sleep "$nap"
  done
}
load_progress(){   # runs beside loadtxoutset: how far the node is, from its own log
  local l p shown="" nap=20 hashing=0
  is_dry && nap=1
  while sleep "$nap"; do
    l=$(as_u tail -c 20000 "$CDIR/debug.log" 2>/dev/null | grep -a '\[snapshot\]' | tail -1)
    case "$l" in
      *"coins loaded ("*) p=$(printf '%s' "$l" | sed -n 's/.*coins loaded (\([0-9]*\)[0-9.]*%.*/\1/p')
        [ -n "$p" ] && [ "$p" != "$shown" ] || continue
        shown=$p; say "  loading the snapshot: $p% of the coins"; status_set "step $STEP_N/$TOTAL_STEPS: loading the UTXO snapshot: $p%"
        rstate extracting $(( UX_BYTES / 100 * p )) "$UX_BYTES";;
      *"] loaded "*) [ $hashing = 0 ] || continue
        hashing=1; say "  all coins are read. Bitcoin Knots now checks them against the hash that is compiled into it (some minutes)"
        status_set "step $STEP_N/$TOTAL_STEPS: Bitcoin Knots is checking the UTXO snapshot's content"
        rstate extracting "$UX_BYTES" "$UX_BYTES";;
    esac
  done
}
snapshot_service_stopped(){
  local info key value load="" state="" pid="" fields=0
  info=$(timeout 4 systemctl show knots-node.service -p LoadState -p ActiveState -p MainPID 2>/dev/null) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load=$value;; ActiveState) state=$value;; MainPID) pid=$value;; *) return 1;;
    esac
    fields=$(( fields + 1 ))
  done <<< "$info"
  case "$load:$state:$pid:$fields" in
    loaded:inactive:0:3|loaded:failed:0:3|not-found:inactive:0:3) return 0;;
  esac
  return 1
}
snapshot_import_state(){   # active, idle, or unknown; a failed query never establishes idle by itself
  local info state
  if info=$(as_u timeout 4 /usr/local/bin/bitcoin-cli -datadir="$DD" getrpcinfo 2>/dev/null); then
    state=$(printf '%s' "$info" | jq -er '
      if type == "object" and (.active_commands | type == "array") and
         all(.active_commands[]; type == "object" and (.method | type == "string") and
             (.method | length > 0) and (.duration | type == "number") and .duration >= 0)
      then if any(.active_commands[]; .method == "loadtxoutset") then "active" else "idle" end
      else "unknown" end' 2>/dev/null) || state=unknown
    case "$state" in active|idle) printf '%s\n' "$state";; *) echo unknown;; esac
  elif snapshot_service_stopped; then echo idle
  else echo unknown; fi
}
snapshot_import_refuse(){
  printf '\nERROR [AP-416]: %s\n' "$*"
  say "This refusal leaves the node and pending installation state in place. Check: sudo alphapool-node status"
  say "Wait for the import to finish (or resolve the inspection error), then run the same command again."
  # An import outlives its installer worker. Neither die's fast_abort nor EXIT's upgrade rollback may stop it.
  trap - EXIT
  drain
  exit 1
}
snapshot_import_guard(){
  local state
  state=$(snapshot_import_state)
  case "$state" in
    idle) return 0;;
    active) snapshot_import_refuse "Bitcoin Knots is still loading a UTXO snapshot; this command cannot continue yet.";;
    *) snapshot_import_refuse "Bitcoin Knots' active imports could not be determined safely. No further recovery changes or another snapshot load will be attempted by this command.";;
  esac
}
network_error(){ die AP-415 "$* Fix the problem, then run: sudo alphapool-node repair"; }
network_pause_dir(){
  local o
  [ -d "$ETC" ] && [ ! -L "$ETC" ] && o=$(stat -c '%u %a' -- "$ETC" 2>/dev/null) &&
    [ "${o%% *}" = 0 ] && (( (8#${o##* } & 8#022) == 0 ))
}
network_pause_check(){
  network_pause_dir && plain_own "$NETWORK_PAUSE" &&
    [ "$(stat -c '%a %s' -- "$NETWORK_PAUSE")" = "600 9" ] && [ "$(cat -- "$NETWORK_PAUSE")" = 'format=1' ]
}
network_pause(){
  local info
  network_restore                         # settle an earlier pause before claiming a new one
  info=$(cli getnetworkinfo 2>/dev/null) || network_error "Bitcoin Knots did not report whether networking is enabled."
  # An operator's offline node is not ours to turn back on.
  if printf '%s' "$info" | jq -e '.networkactive == false' >/dev/null 2>&1; then return 0; fi
  printf '%s' "$info" | jq -e '.networkactive == true' >/dev/null 2>&1 || network_error "Bitcoin Knots returned no boolean networking state."
  network_pause_dir || network_error "$ETC must be a directory owned by root that other users cannot write."
  ( umask 077; new_file "$NETWORK_PAUSE.new" && printf 'format=1\n' > "$NETWORK_PAUSE.new" ) &&
    mv -T -f -- "$NETWORK_PAUSE.new" "$NETWORK_PAUSE" && network_pause_check &&
    sync -f "$NETWORK_PAUSE" && sync -f "$ETC" || network_error "The networking recovery marker could not be safely saved."
  cli setnetworkactive false >/dev/null 2>&1 || network_error "Bitcoin Knots could not pause networking; the recovery marker was kept."
}
network_restore(){
  local info
  snapshot_import_guard
  [ -e "$NETWORK_PAUSE" ] || [ -L "$NETWORK_PAUSE" ] || return 0
  network_pause_check || network_error "$NETWORK_PAUSE is not a valid root-owned networking recovery marker; inspect its owner, permissions and content."
  # Idempotent start preserves a running node, and also recovers after fast_abort stopped it.
  NETWORK_RECOVERY=1
  run_q systemctl start knots-node.service || network_error "Bitcoin Knots could not be started for networking recovery."
  as_u timeout 35 /usr/local/bin/bitcoin-cli -datadir="$DD" -rpcwait -rpcwaittimeout=30 getnetworkinfo >/dev/null 2>&1 ||
    network_error "Bitcoin Knots did not answer within 30 seconds after starting it; check alphapool-node logs node."
  snapshot_import_guard
  cli setnetworkactive true >/dev/null 2>&1 || network_error "Bitcoin Knots refused to restore networking; the recovery marker was kept."
  info=$(cli getnetworkinfo 2>/dev/null) && printf '%s' "$info" | jq -e '.networkactive == true' >/dev/null 2>&1 ||
    network_error "Bitcoin Knots did not confirm networking is enabled; the recovery marker was kept."
  rm -f -- "$NETWORK_PAUSE" || network_error "Networking is enabled, but the recovery marker could not be removed."
  sync -f "$ETC" 2>/dev/null; return 0       # a stale marker after a crash only repeats the confirmed restore
}
fast_load(){   # FILE OUT_FILE
  local f=$1 out=$2 hf rc msg t0
  snapshot_import_guard
  # The node reads the file itself, as the node user. The file does not go into the node's folders: it moves into a
  # directory of root's which the node user may read and not write, and root removes it from there afterwards.
  shared_dir "$HAND" || die AP-211 "$HAND is there already, but not as a directory of root's alone. The installer hands the snapshot file to the node there and will not use it like this. Look at it, remove it (rm -rf $HAND), then run again."
  hf=$HAND/${f##*/}
  rm -f -- "$hf"; mv -T -f -- "$f" "$hf" && chgrp -- "$U" "$hf" && chmod 0640 -- "$hf" || die AP-413 "the snapshot file could not be put where the node reads it ($HAND; is the disk full?)"
  say_t "  the node is loading the UTXO snapshot (about 10 to 40 minutes on a small server; it talks to no peers meanwhile)"
  rstate extracting 0 "$UX_BYTES"; status_set "step $STEP_N/$TOTAL_STEPS: loading the UTXO snapshot"
  console_note "loading the UTXO snapshot into the node (10 to 40 minutes)"
  t0=$(date +%s)
  network_pause
  load_progress & BG_PID=$!
  as_u /usr/local/bin/bitcoin-cli -datadir="$DD" -rpcclienttimeout=0 loadtxoutset "$hf" > "$out" 2>&1; rc=$?
  kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""
  network_restore
  msg=$(tr '\n' ' ' < "$out" | sed 's/  */ /g' | head -c 700)
  if [ $rc -eq 0 ]; then
    rm -f -- "$hf"
    say_t "  loaded in $(dur $(( $(date +%s) - t0 ))): $(jq -r '"\(.coins_loaded) coins, the chain state of block \(.base_height)"' "$out" 2>/dev/null || printf '%s' "$msg")"
    return 0
  fi
  case "$msg" in
    *"more than once"*) rm -f -- "$hf"; say "  the node had loaded the snapshot already"; return 0;;
    *"not recognized"*)
      rm -f -- "$hf" "$UJ"
      die AP-411 "the Bitcoin Knots build on this server ($(knots_version)) refused the UTXO snapshot of block $UX_HEIGHT: that block is not compiled into it. $(printf '%s' "$msg" | sed -n 's/.*\(The following snapshot heights are available: [0-9, ]*[0-9]\).*/\1./p') Use AlphaPool's tested build (--knots alphapool), or a snapshot your build knows (--utxo-*), or --sync network.";;
    *"Bad snapshot"*|*"Mismatch in coins count"*|*"Unable to parse metadata"*)
      rm -f -- "$hf"; kv_set "$UJ" verified ""
      die AP-412 "Bitcoin Knots refused the content of the UTXO snapshot, and the file was deleted. The node said: $msg";;
  esac
  die AP-413 "the node did not load the UTXO snapshot. The node said: ${msg:-nothing (did it stop? alphapool-node logs node)}"
}
fast_done(){   # the node has its chain start: the install is complete; what is left is the node's own work
  network_restore
  rm -f -- "$DL/$UX_FILE" "$DL/$UX_FILE.aria2"; hand_ok && rm -f -- "$HAND/$UX_FILE"
  kv_set "$STATE" chain_start assumeutxo; kv_set "$STATE" chain_start_height "$UX_HEIGHT"
  kv_set "$STATE" chain_start_base "$UX_BASE"; kv_set "$STATE" chain_start_at "$(date -u +%FT%TZ)"
  rstate "done" "$UX_BYTES" "$UX_BYTES"
  rm -f "$UJ"; FAST_OPEN=0
  install_complete
  write_versions
  say "  the install is complete. The node now validates every block since block $(sep "$UX_HEIGHT") by itself"
}
fast_start(){   # step 9 of a validated start. Every part can be run again: after a reboot, after a failed attempt.
  local out
  snapshot_import_guard
  FAST_OPEN=1
  uj_load
  work_dir; out=$WORK/loadtxoutset.out
  if snapshot_active; then say "  the node has loaded the UTXO snapshot of block $(sep "$UX_HEIGHT") already"; fast_done; return 0; fi
  if [ "$(cli getblockcount 2>/dev/null || echo 0)" -ge "$UX_HEIGHT" ] 2>/dev/null; then
    say "  this node has validated the chain past block $(sep "$UX_HEIGHT") by itself already: it needs no snapshot"
    network_restore
    rm -f "$DL/$UX_FILE" "$DL/$UX_FILE.aria2" "$UJ"; FAST_OPEN=0
    kv_set "$STATE" chain_start network; install_complete; return 0
  fi
  utxo_file_ready                      # step 5 did this; after a reboot or a failed attempt it is made sure of again
  [ -z "$UX_BASE" ] || utxo_ask_build
  fast_wait_headers
  fast_load "$DL/$UX_FILE" "$out"
  fast_done
}
sync_eta_s(){   # seconds left as the gateway starter measures them while it waits for the node; nothing if there is no fresh measurement
  local f=$RUN/sync-progress ts eta
  [ -r "$f" ] || return 0
  ts=$(kv_get "$f" ts || true); eta=$(kv_get "$f" eta_s || true)
  [[ $ts =~ ^[0-9]+$ ]] && [[ $eta =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - ts )) -le 300 ] || return 0
  printf '%s' "$eta"
}
# long_catch_up: after a validated start the node validates every block from the snapshot to the tip.
#   0 = the node is at the tip.
#   3 = it will take long: the installer watched it start (blocks left, measured time left) and hands over to the
#       gateway starter, which starts the gateway at the tip and writes READY to the login screen.
#   2 = no new block for STALL_S seconds (the node keeps trying by itself).
CATCHUP_WATCH=$(num_or "${AP_CATCHUP_WATCH:-}" 420)       # how long the installer watches before it decides
CATCHUP_STAY=$(num_or "${AP_CATCHUP_STAY:-}" 2700)        # it stays to the end if the measured time left is at most this
long_catch_up(){
  local info b h peers now t0 last=0 lastb=-1 moved every=60 eta secs nap=15
  is_dry && nap=1
  t0=$(date +%s); moved=$t0
  while :; do
    info=$(cli getblockchaininfo 2>/dev/null)
    if [ -n "$info" ] && synced "$info"; then
      say_t "  the node is at the tip: block $(sep "$(printf '%s' "$info" | jq -r .blocks)") ($(dur $(( $(date +%s) - t0 ))))"; return 0
    fi
    now=$(date +%s)
    b=$(printf '%s' "$info" | jq -r '.blocks // 0' 2>/dev/null); h=$(printf '%s' "$info" | jq -r '.headers // 0' 2>/dev/null)
    [[ $b =~ ^[0-9]+$ ]] || b=0; [[ $h =~ ^[0-9]+$ ]] || h=0
    if [ "$b" != "$lastb" ]; then lastb=$b; moved=$now; fi
    secs=$(sync_eta_s); eta=""; [ -z "$secs" ] || eta="$(eta_text "$secs") at the current speed"
    if [ $(( now - last )) -ge "$every" ]; then
      peers=$(cli getconnectioncount 2>/dev/null); [[ $peers =~ ^[0-9]+$ ]] || peers=0
      if [ "$h" -gt "$b" ]; then
        say "  validating the blocks since the snapshot: block $(sep "$b") of $(sep "$h"), $(sep $(( h - b ))) left${eta:+, $eta}, $peers peers"
        status_set "validating blocks: $(sep $(( h - b ))) left${eta:+, $eta}"
      else say "  waiting for the node ($peers peers)"; fi
      last=$now
    fi
    [ $(( now - moved )) -lt "$STALL_S" ] || return 2
    if [ $(( now - t0 )) -ge "$CATCHUP_WATCH" ] && [ "$h" -gt "$b" ]; then
      # stay only when it is measured AND short; with no measurement after the watch, the blocks left decide
      if { [ -n "$secs" ] && [ "$secs" -gt "$CATCHUP_STAY" ]; } || { [ -z "$secs" ] && [ $(( h - b )) -gt 3000 ]; }; then
        CATCHUP_LEFT=$(( h - b )); CATCHUP_ETA=$eta; return 3
      fi
    fi
    sleep "$nap"
  done
}
CATCHUP_LEFT=0; CATCHUP_ETA=""
handover_next_steps(){
  say "The install is done and the node keeps working by itself. You can close this window."
  say "To watch progress here, run: alphapool-node status --watch. Or type exit: the login screen shows the progress and updates every 5 minutes."
  say_zh "安装已经完成，节点会自行继续工作。您可以关闭此窗口。"
  say_zh "若要在这里查看进度，请运行：alphapool-node status --watch。也可以输入 exit：登录界面会显示进度，每 5 分钟更新一次。"
}
catchup_handover(){   # the long catch-up goes on without the installer: what is left, how long, where to look
  say ""
  say "The install is complete, and the node is NOT READY yet. It is validating $(sep "$CATCHUP_LEFT") blocks: ${CATCHUP_ETA:-time left is still being measured}."
  say "  - Keep your rigs mining where they are. Nothing is lost by waiting: this server takes no rigs before READY."
  say "  - The gateway starts by itself when the node is at the chain tip. No command is needed, and you can log out."
  say "  - See how far it is at any time:  alphapool-node status   (blocks left and the time left; it says READY at the end)"
  say "    The same line is on this server's login screen in your provider's web console."
  say "  - The history before the snapshot is checked afterwards, in the background. It does not affect mining."
  say_zh "安装已完成, 但节点还未就绪: 正在验证 $(sep "$CATCHUP_LEFT") 个区块. 在显示 READY 之前请让矿机继续在原处挖矿."
  say_zh "查看进度: alphapool-node status (显示剩余区块和时间, 完成后显示 READY). 网关会在节点同步完成后自动启动."
  status_set "validating blocks: $(sep "$CATCHUP_LEFT") left${CATCHUP_ETA:+, $CATCHUP_ETA}"
  issue_set "NOT READY yet. The node is validating blocks: $(sep "$CATCHUP_LEFT") left${CATCHUP_ETA:+, $CATCHUP_ETA}. Keep mining where you are until this says READY. Status: alphapool-node status"
  console_note "NOT READY yet: validating $(sep "$CATCHUP_LEFT") blocks${CATCHUP_ETA:+, $CATCHUP_ETA}. Progress: alphapool-node status"
}

# ==== step 5: chain data ===============================================================================================
step_chain(){
  step 5 "Chain data"
  [ "$SYNC_MODE" = assumeutxo ] || uj_drop
  if has_u -e "$DD/.alphapool-restore-in-progress"; then
    # An installer before 2026-10-08.1 was unpacking AlphaPool's pre-synced chain copy here and was cut short. That
    # copy is gone; what is left of the unpack is removed, by a process of the node user (its own folder).
    say "  an unpack of an earlier installer was cut short here: its partial chain data is removed"
    as_u rm -rf "$DD/blocks" "$DD/chainstate"
    as_u rm -f "$DD/.alphapool-restore-in-progress"
  elif uj_pending; then :                                   # a validated start that is not finished: it goes on below
  elif chain_there; then
    say "  chain data is already on this server: kept (never wiped)"; rstate skipped; return 0
  fi
  case "$SYNC_MODE" in
    network) say "  no snapshot: the node syncs from the Bitcoin network (this takes days on a small server)"; rstate skipped;;
    *)       utxo_prepare;;
  esac
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
  [ "$NODE_CHAIN" = main ] || printf 'chain=%s\n' "$NODE_CHAIN"
  [ -z "$NODE_CONF_EXTRA" ] || printf '%b\n' "$NODE_CONF_EXTRA"
  return 0
}
conf_unreadable(){ has_u -e "$BTC_CONF" && ! has_u -r "$BTC_CONF"; }      # bitcoin.conf is there, and the node user cannot read it
check_blockmaxweight(){
  conf_unreadable && return 0                 # (said by write_bitcoin_conf; its values are not known then)
  local v; v=$(conf_u blockmaxweight)
  if [ -z "$v" ] || ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -gt "$PAYOUT_MAX_BLOCKWEIGHT" ]; then
    local shown=${v:-unset}
    warn "bitcoin.conf has blockmaxweight=$shown. AlphaPool's payout requirement is blockmaxweight=$PAYOUT_MAX_BLOCKWEIGHT or lower: AlphaPool pays miners in the block's coinbase, and above it a busy mempool can leave too little room for that payout list, so your gateway cannot build AlphaPool jobs. Your setting is kept; set it in $BTC_CONF and run: alphapool-node restart node"
  fi
}
write_bitcoin_conf(){
  local rp
  if conf_unreadable; then
    warn "the node user $U cannot read $BTC_CONF (does the file belong to another user now, for example after it was replaced as root?). The node cannot start with it like this. Give it back: chown $U:$U $BTC_CONF"
  fi
  rp=$(conf_u rpcpassword); [[ $rp =~ ^[0-9a-f]{48}$ ]] || rp=$(rand_hex 24)
  write_managed "$BTC_CONF" 0600 user < <(render_bitcoin_conf "$rp") \
    || die AP-505 "bitcoin.conf could not be written by the node user $U in its data folder ($DD). Does that folder still belong to $U?"
  [ "$WM_RESULT" = written ] && NODE_CHANGED=1
  check_blockmaxweight
}
write_gateway_conf(){
  local base='{}' ru rp ap tmp ok cur la keep=0
  conf_unreadable && keep=1                           # then the RPC login in the gateway config stays exactly as it is
  cur=$(as_u cat "$GW_CONF" 2>/dev/null || true)       # read, saved and written by the node user (its folder)
  if [ -n "$cur" ]; then
    if printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1; then base=$cur
    else as_u cp -p "$GW_CONF" "$GW_CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"; warn "the gateway config was not valid JSON: saved a copy and wrote a fresh one"; fi
  fi
  ru=$(conf_u rpcuser); rp=$(conf_u rpcpassword)
  ap=$(printf '%s' "$base" | jq -r '.api.admin_password // ""'); [ -n "$ap" ] || ap=$(rand_hex 24)
  work_dir; tmp=$(mktemp "$WORK/gwconf.XXXXXX") || die AP-505 "the gateway configuration could not be written (no scratch file)"
  # AlphaPool's keys are set; every other key you added or changed is kept (defaults only fill what is missing).
  printf '%s' "$base" | jq --arg addr "$ADDRESS" --arg tag "$TAG" --arg ph "$POOL_HOST" --argjson pp "$POOL_PORT" \
      --arg pk "$POOL_PUBKEY" --argjson sp "$STRATUM_PORT" --arg ru "$ru" --arg rp "$rp" --arg ap "$ap" \
      --arg ik "$GWD/identity.key" --arg cookie "$DD/.cookie" --arg keep "$keep" '
    def dflt(p; v): if getpath(p) == null then setpath(p; v) else . end;
    (if $keep == "1" then .
     elif ($ru != "" and $rp != "") then .bitcoind.rpcuser = $ru | .bitcoind.rpcpassword = $rp | del(.bitcoind.rpccookiefile)
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
  la=$(jq -r '.api.listen_addr' "$tmp" 2>/dev/null)
  if [ "$(cat "$tmp")" = "$cur" ]; then rm -f "$tmp"
  else put_as_user "$GW_CONF" 0600 < "$tmp" || die AP-505 "the gateway configuration could not be written"; rm -f "$tmp"; GW_CHANGED=1; fi
  [ "$la" = 127.0.0.1 ] || warn "the gateway's admin API listens on $la (your setting); the firewall does not open port 7152"
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
  write_gate
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
  write_versions
  say "  node: prune 4000 MB, dbcache $(dbcache_mb) MB, blockmaxweight $(conf_u blockmaxweight); RPC on 127.0.0.1 only"
  say "  gateway: pays $ADDRESS, stratum :$STRATUM_PORT, admin page on 127.0.0.1:7152 only, pool $POOL_HOST:$POOL_PORT"
}

write_gate(){
  # A separate issue fragment survives progress/READY rewrites of alphapool.issue on the provider console.
  if [ "$KNOTS_VERIFY" = pin ] && [ "$(kv_get "$STATE" knots_source || true)" = alphapool ]; then
    install -d -m 0755 /etc/issue.d
    printf '%s\n' "$M_TRUST" > /etc/issue.d/alphapool-build.issue
  else
    rm -f /etc/issue.d/alphapool-build.issue
  fi
  install -d -m 0755 "$LIB"
  cat > "$LIB/start-gateway-when-synced.new" <<'GATE'
#!/bin/bash
# Waits until the local node is at the chain tip, then starts datum-gateway: no job from a stale node, and no idle
# connection to AlphaPool while the node syncs. While it waits it measures how fast the node validates blocks and
# writes how far the node is to /run/alphapool/sync-progress (alphapool-node status and the installer read it) and to
# the login screen. When the gateway has AlphaPool's job it writes READY to the login screen, and exits.
set -u
CLI=${AP_GATE_CLI:-/usr/local/bin/bitcoin-cli}; R=${AP_GATE_RUN:-/run/alphapool}
ETC=${AP_GATE_ETC:-/etc/alphapool}; ISSUE=${AP_GATE_ISSUE:-/etc/issue.d/alphapool.issue}
GW_API=${AP_GATE_GW_API:-http://127.0.0.1:7152}
# The node is asked by a process of the node user: bitcoin-cli itself reads bitcoin.conf and the RPC cookie, which are
# in that user's folder, and root opens nothing there.
as_u(){ ( cd / 2>/dev/null; exec env HOME=/home/alphapool USER=alphapool LOGNAME=alphapool setpriv --reuid=alphapool --regid=alphapool --init-groups -- "$@" ); }
cli(){ as_u timeout 20 "$CLI" -datadir=/home/alphapool/.bitcoin "$@"; }
val(){ sed -n "s/^$1=//p" "$ETC/node.conf" 2>/dev/null | tail -1; }
sep(){ printf '%s' "$1" | sed -E ':a;s/^([0-9]+)([0-9]{3})/\1,\2/;ta'; }
eta_text(){
  local s=$1
  if [ "$s" -lt 300 ]; then printf 'under 5 min'
  elif [ "$s" -lt 5400 ]; then printf 'about %d min' $(( (s + 150) / 300 * 5 ))
  else printf 'about %d h %02d min' $(( s / 3600 )) $(( s % 3600 / 600 * 10 )); fi
}
login_screen(){   # while the installer works, it writes the login screen itself
  [ -e "$ETC/install-in-progress" ] && return 0
  mkdir -p "$(dirname "$ISSUE")" 2>/dev/null
  printf 'AlphaPool node: %s\n\n' "$*" > "$ISSUE.new" 2>/dev/null && mv -f "$ISSUE.new" "$ISSUE" 2>/dev/null
  timeout 5 agetty --reload >/dev/null 2>&1
  return 0
}
rigs_at(){
  local h p
  h=$(val PUBLIC_HOST); [ -n "$h" ] || h=$(val DETECTED_HOST); p=$(val STRATUM_PORT)
  printf 'stratum+tcp://%s:%s' "${h:-<this server>}" "${p:-23334}"
}
mkdir -p "$R"                      # /run is emptied at every boot
T=(); B=()                         # when, and at which block: one sample per round, the last 15 minutes
shown=0
while :; do
  info=$(cli getblockchaininfo 2>/dev/null)
  now=$(date +%s)
  if [ -n "$info" ] && printf '%s' "$info" | jq -e '.initialblockdownload == false and .blocks == .headers and .headers > 0' >/dev/null 2>&1; then
    printf 'synced %s\n' "$(date -u +%FT%TZ)" > "$R/gateway-gate" 2>/dev/null
    rm -f "$R/sync-progress"
    break
  fi
  printf 'waiting for the node to catch up %s\n' "$(date -u +%FT%TZ)" > "$R/gateway-gate"
  b=$(printf '%s' "$info" | jq -r '.blocks // empty' 2>/dev/null); h=$(printf '%s' "$info" | jq -r '.headers // empty' 2>/dev/null)
  if [[ ${b:-} =~ ^[0-9]+$ ]] && [[ ${h:-} =~ ^[0-9]+$ ]] && [ "$h" -gt "$b" ]; then
    # Nothing is measured across a jump of the block count. While a validated start is under way (its journal is
    # there) the node counts the blocks of another chain state than the one it has once the snapshot is loaded: no
    # sample is kept until the load is done. A count that went down is a new beginning as well.
    if [ -e "$ETC/validated-start.journal" ]; then T=(); B=()
    else
      [ "${#B[@]}" -gt 0 ] && [ "$b" -lt "${B[-1]}" ] && { T=(); B=(); }
      T+=("$now"); B+=("$b")
    fi
    eta=""; per_min=0
    if [ "${#T[@]}" -gt 0 ]; then
      while [ "${#T[@]}" -gt 2 ] && [ $(( now - T[0] )) -gt 900 ]; do T=("${T[@]:1}"); B=("${B[@]:1}"); done
      dt=$(( now - T[0] )); db=$(( b - B[0] ))
      # the time left, from what the node really did in the last minutes; no estimate before there is something to measure
      if [ "$dt" -ge "${AP_GATE_MEASURE:-120}" ] && [ "$db" -gt 0 ]; then eta=$(( (h - b) * dt / db )); per_min=$(( db * 60 / dt )); fi
    fi
    printf 'ts=%s\nblocks=%s\nheaders=%s\nleft=%s\nper_min=%s\neta_s=%s\n' "$now" "$b" "$h" $(( h - b )) "$per_min" "$eta" > "$R/sync-progress.new" \
      && mv -f "$R/sync-progress.new" "$R/sync-progress"
    if [ $(( now - shown )) -ge "${AP_GATE_SCREEN:-300}" ]; then
      login_screen "NOT READY yet. The node is validating blocks: $(sep $(( h - b ))) left${eta:+, $(eta_text "$eta") at the current speed}. Keep mining where you are until this says READY. Status: alphapool-node status"
      shown=$now
    fi
  else rm -f "$R/sync-progress"; T=(); B=(); fi
  sleep "${AP_GATE_SLEEP:-30}"
done
systemctl start datum-gateway.service || exit 1
# READY is when the gateway has AlphaPool's job: payouts to addresses other than the miner's own
own=$(val ADDRESS); n=0
for _ in $(seq 1 "${AP_GATE_JOB_TRIES:-30}"); do
  n=$(timeout 3 curl -sS "$GW_API/coinbaser" 2>/dev/null | head -c 200000 | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${own:-none}")
  if [ "${n:-0}" -gt 0 ]; then
    login_screen "READY - point your rigs at $(rigs_at) (worker: anything). Status: alphapool-node status"
    exit 0
  fi
  sleep "${AP_GATE_JOB_SLEEP:-10}"
done
login_screen "the node is at the chain tip and the gateway runs, but it has no AlphaPool job yet. Check: alphapool-node status"
exit 0
GATE
  chmod 0755 "$LIB/start-gateway-when-synced.new" && mv -f "$LIB/start-gateway-when-synced.new" "$LIB/start-gateway-when-synced"
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
cli(){ as_u timeout 30 /usr/local/bin/bitcoin-cli -datadir="$DD" "$@"; }   # as the node user: bitcoin-cli itself reads bitcoin.conf and the cookie
step_start(){
  local log0 t0
  step 8 "Starting the node"
  log0=$(node_log_size); t0=$(date +%s)
  run systemctl daemon-reload
  if [ "$NODE_CHANGED" = 1 ] && systemctl is-active --quiet knots-node.service 2>/dev/null; then
    say "  the node software or its settings changed: restarting the node"
    run systemctl restart knots-node.service
  fi
  run_q systemctl enable --now knots-node.service || die AP-507 "the node did not start (journalctl -u knots-node)"
  if ! is_dry; then
    local i ok=1
    for i in $(seq 1 120); do cli getblockchaininfo >/dev/null 2>&1 && { ok=0; break; }; sleep 5; done
    if [ $ok -ne 0 ] && node_refused_snapshot "$log0" "$t0"; then
      die AP-414 "this Bitcoin Knots build cannot run this node yet: the node started from a UTXO snapshot and has not finished checking the history before it, and this build does not know that snapshot's block (Bitcoin Knots said: Assumeutxo data not found for the given blockhash). Go back to the build the node had (alphapool-node switch knots alphapool, or your own build again), and switch when the history check is complete: alphapool-node status shows it."
    fi
    [ $ok -eq 0 ] || die AP-507 "the node started but does not answer after 10 minutes (alphapool-node logs node)"
    say_t "  the node is running: block $(cli getblockcount 2>/dev/null)"
  fi
  if [ "$GW_CHANGED" = 1 ] && systemctl is-active --quiet datum-gateway.service 2>/dev/null; then
    say "  the gateway software or its settings changed: restarting the gateway"
    run systemctl restart datum-gateway.service
  fi
  [ -n "$ALIAS_PORTS" ] && { run_q systemctl enable --now datum-port-aliases.service || warn "the stratum port aliases could not be set up"; }
  run_q systemctl enable --now alphapool-gateway-start.service || die AP-507 "the gateway starter did not start (journalctl -u alphapool-gateway-start)"
  if uj_pending; then
    say "  the node is running. The install is complete when the UTXO snapshot is loaded (step 9); the gateway starts"
    say "  by itself once the node is at the chain tip"
    return 0
  fi
  if [ -z "$(kv_get "$STATE" chain_start || true)" ]; then      # how this node got its chain (alphapool-node status says it)
    if has_u -e "$CDIR/chainstate_snapshot"; then kv_set "$STATE" chain_start assumeutxo      # chain data kept from a validated start
    elif [ "$SAVED_SYNC" = snapshot ]; then kv_set "$STATE" chain_start presynced
    else kv_set "$STATE" chain_start network; fi
  fi
  install_complete
  say "  install complete: the gateway starts by itself once the node has caught up"
}
install_complete(){
  network_restore
  rm -f "$ETC/install-in-progress"
  printf 'ok %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"
  kv_set "$STATE" installed_at "$(date -u +%FT%TZ)"
}

# ==== step 9: catching up ==============================================================================================
# count_pool_payees OWN_ADDRESS < the gateway's /coinbaser page: payouts to addresses OTHER than the miner's own.
# Before AlphaPool's payout list arrives the page shows one row paying the whole block to the miner's own address:
# that is the gateway's fallback, not an AlphaPool job, so it counts 0.
count_pool_payees(){ head -c 200000 | grep -oE 'bc1[a-z0-9]{20,}|[13][A-Za-z0-9]{25,}' | sort -u | grep -cvxF "${1:-none}"; }
synced(){   # INFO_JSON
  printf '%s' "$1" | jq -e '.initialblockdownload == false and .blocks == .headers and .headers > 0' >/dev/null 2>&1
}
step_catch_up(){
  step 9 "Catching up with the network"
  if is_dry && [ "${AP_DRY_CATCHUP:-0}" != 1 ]; then say "  DRY: skipped"; return 0; fi
  if uj_pending; then fast_start; fi
  if [ "$(kv_get "$STATE" chain_start || true)" = assumeutxo ]; then
    # after a validated start the node validates every block from the snapshot to the tip: hours, shown with the time left
    long_catch_up; case $? in
      0) ;;
      3) [ "$SUMMARY_SHOWN" = 1 ] || summary
         catchup_handover; return 0;;
      *) warn "the node has not received a new block for $(( STALL_S / 60 )) minutes and is not at the tip yet. It keeps trying by itself; the nodes it is connected to may not have the blocks it needs. Watch it: alphapool-node status"
         return 0;;
    esac
    is_dry && return 0
    wait_for_job; return 0
  fi
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
      say "  the node is far behind ($(printf '%s' "$info" | jq -r '(.verificationprogress // 0) * 100 | floor')% verified): it syncs the chain from the network, which takes days on a small server."
      say "  The installer does not wait for that. The gateway starts by itself once the node is at the tip;"
      say "  alphapool-node status shows the blocks left and the time left, and says READY at the end."
      return 0
    fi
    [ $(( now - t0 )) -lt 5400 ] || { say "  still catching up after 90 minutes; the gateway starts by itself once the node is at the tip (alphapool-node status)"; return 0; }
    sleep "$nap"
  done
  is_dry && return 0
  wait_for_job
}
wait_for_job(){   # the node is at the tip: the gateway starts and must get AlphaPool's job. Sets READY.
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
READY=0; SUMMARY_SHOWN=0
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
  SUMMARY_SHOWN=1
  case "$host" in "<"*) ;; *) [ -w "$CONF" ] && kv_set "$CONF" DETECTED_HOST "$host";; esac   # for alphapool-node status
  say ""
  say "=================================================================================="
  if [ "$READY" = 1 ]; then say "  AlphaPool node is READY"; say_zh "  AlphaPool 节点已就绪"
  else say "  AlphaPool node installed (the gateway starts once the node has caught up)"; say_zh "  AlphaPool 节点已安装"; fi
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
  say_zh "  矿机连接地址:  stratum+tcp://$host:$STRATUM_PORT"
  say_zh "  矿工名/密码:   任意 (例如 rig1)"
  say_zh "  收款地址:      $ADDRESS"
  say_zh "  查看状态:      alphapool-node status      卸载: alphapool-node uninstall"
  [ "$HEARTBEAT" = on ] && say_zh "  关闭状态上报:  alphapool-node heartbeat off"
  say "=================================================================================="
  if [ "$READY" != 1 ]; then
    say "NOT READY yet: keep your rigs mining where they are until this says READY. How far it is: alphapool-node status"
    say_zh "还未就绪: 在显示 READY 之前, 请让矿机继续在原来的地方挖矿. 查看进度: alphapool-node status"
  fi
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    say "Warnings:"; for w in "${WARNINGS[@]}"; do say "  - $w"; done
  fi
  if [ "$READY" = 1 ]; then
    issue_set "READY - point your rigs at stratum+tcp://$host:$STRATUM_PORT (worker: anything). Status: alphapool-node status"
    console_note "READY: point your rigs at stratum+tcp://$host:$STRATUM_PORT"
  else
    issue_set "installed, NOT READY yet: the gateway starts once the node has caught up. Keep mining where you are until this says READY. Status: alphapool-node status"
  fi
}

# refresh_node_files: everything this installer writes besides the two programs and the chain: the everyday command,
# the gateway starter, the service units, the needrestart rule and, if it is on, the heartbeat agent. A node gets a
# newer installer's version of them with the upgrade command, in place: no download, no re-sync, no restart of the
# node. A file you edited stays as it is (the installer's version goes next to it as <file>.alphapool-new); a unit
# that changed takes effect when its service next starts.
refresh_node_files(){
  local hb
  write_cli; write_gate; write_needrestart
  write_units
  write_resume_unit
  hb=$(kv_get "$CONF" HEARTBEAT || true)
  if [ "$hb" = on ] && [ -e "$LIB/heartbeat-agent" ]; then write_agent; fi
  return 0
}

# ==== upgrade: this installer's pinned Bitcoin Knots and gateway, in place =============================================
# Chain data, settings, firewall and your edits are not touched. The upgrade is a transaction:
#   1. everything is downloaded and verified, and the new programs are put in a set of their own, BEFORE anything stops;
#   2. the programs installed now are in a set too (the way back), and a journal (/etc/alphapool/upgrade.journal) says
#      which set was active, which one comes, and the step reached;
#   3. the gateway stops, then the node; ONE rename makes the new set active; the node starts, then the gateway starter;
#   4. the node must answer and the gateway must come back, each as the new program. If any step fails, the previous
#      set is made active again and started: the server ends with all the new programs running, or all the old ones.
# A crash, kill -9, power cut or reboot in the middle leaves the journal: the next start of the server (the resume
# unit) and the next run of the installer finish the upgrade from it, or put the previous set back.
UPGRADE_KNOTS=""; UPGRADE_GW=""; UP_K=""; UP_G=""
UPGRADE_WAIT=$(num_or "${AP_UPGRADE_WAIT:-}" 600)
RB=$LIB/rollback                # the way back of installers before 2026-10-07.2; removed after the next upgrade
knots_label(){ local v; v=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1 | sed -E 's/^.* version //'); printf '%s' "${v:-unknown}"; }
gw_label(){ local l; l=$(kv_get "$STATE" gateway_label 2>/dev/null || true); printf '%s%s' "${l:+$l, }" "sha256 $(sha_u "$GW_BIN" | cut -c1-12)..."; }
restarts(){ local n; n=$(systemctl show -p NRestarts --value "$1" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
node_comes_up(){   # the node answers within UPGRADE_WAIT seconds; gives up early when systemd keeps restarting it
  local t0 n0
  t0=$(date +%s); n0=$(is_dry && echo 0 || restarts knots-node.service)
  while :; do
    cli getblockchaininfo >/dev/null 2>&1 && return 0
    is_dry || [ $(( $(restarts knots-node.service) - n0 )) -lt 3 ] || return 1
    [ $(( $(date +%s) - t0 )) -lt "$UPGRADE_WAIT" ] || return 1
    sleep "$(is_dry && echo 1 || echo 5)"
  done
}
runs_from(){   # UNIT NAME: the unit's main process IS the program the documented path of NAME leads to now (not an older one still running)
  local pid exe target
  pid=$(systemctl show -p MainPID --value "$1" 2>/dev/null); [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
  target=$(as_u readlink -f "$(doc_path "$2")" 2>/dev/null)      # resolved as the node user: the gateway's path is in its folder
  [ "$exe" = "$target" ] && return 0
  [ "$(as_u head -c 2 "$target" 2>/dev/null)" = '#!' ]            # a script of your own: its interpreter is what runs, so the path cannot tell
}
svc_stop(){   # STEP UNIT...: stop them, and they must really be stopped afterwards
  local step=$1 u; shift
  fault "$step" && return 1
  run systemctl stop "$@" || return 1
  is_dry && return 0
  for u in "$@"; do case "$(unit_state "$u")" in active|activating|deactivating|reloading) return 1;; esac; done
  return 0
}
svc_start(){   # STEP UNIT: a start that fails is a failure, never ignored
  fault "$1" && return 1
  run systemctl start "$2"
}
# gw_settles: after the gateway starter was started. 0 = the gateway runs as the program now installed and stays up;
# 2 = it waits for the node to reach the chain tip and its starter is running (it starts by itself); 1 = neither.
gw_settles(){
  fault gateway-up && return 1
  if is_dry; then
    [ "${AP_DRY_NODE_SYNCED:-1}" = 1 ] && [ "${AP_DRY_GW_WAITS:-0}" = 0 ] || return 2
    gw_smoke "$GW_BIN"; return
  fi
  local t0 n0 n wait=20
  [ "$T_GW_RAN" = 1 ] && wait=$UPGRADE_WAIT
  t0=$(date +%s)
  until synced "$(cli getblockchaininfo 2>/dev/null)"; do     # while the node catches up there is no gateway to judge
    if [ $(( $(date +%s) - t0 )) -ge "$wait" ]; then
      case "$(unit_state alphapool-gateway-start.service)" in active|activating) return 2;; esac
      return 1
    fi
    sleep 5
  done
  t0=$(date +%s); n0=$(restarts datum-gateway.service)
  while [ $(( $(date +%s) - t0 )) -lt 150 ]; do
    [ $(( $(restarts datum-gateway.service) - n0 )) -lt 3 ] || return 1
    if [ "$(unit_state datum-gateway.service)" = active ]; then
      n=$(restarts datum-gateway.service); sleep 20
      [ "$(unit_state datum-gateway.service)" = active ] && [ "$(restarts datum-gateway.service)" = "$n" ] \
        && runs_from datum-gateway.service datum_gateway && return 0
    fi
    sleep 5
  done
  return 1
}
journal_write(){   # STEP: the whole journal, written under another name, flushed, then renamed into place
  ( umask 077; printf 'format=1\nstarted=%s\ninstaller=%s\nold=%s\nnew=%s\nknots=%s\ngateway=%s\ngw_ran=%s\nmode=%s\nstep=%s\n' \
      "$(date -u +%FT%TZ)" "$AP_VERSION" "$T_OLD" "$T_NEW" "$T_K" "$T_G" "$T_GW_RAN" "$T_MODE" "$1" > "$JOURNAL.new" ) || return 1
  sync "$JOURNAL.new" 2>/dev/null
  mv -f "$JOURNAL.new" "$JOURNAL" || return 1
  sync "$ETC" 2>/dev/null
  return 0
}
jstep(){ kv_set "$JOURNAL" step "$1"; sync "$JOURNAL" "$ETC" 2>/dev/null; return 0; }
txn_pending(){ [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ]; }
T_OLD=""; T_NEW=""; T_K=0; T_G=0; T_GW_RAN=1; T_CODE=""; T_WHY=""; T_WAITING=0; T_RB=""; T_MODE=""; MODE_GONE=""
# txn_forward: from a written journal to running programs. Every step can be repeated, so a recovery simply runs it
# again from the top. 0 = the new set is active and runs. 1 = a step failed: T_CODE and T_WHY say which one, and
# nothing here tries to repair it (txn_rollback does).
txn_forward(){
  local r log0 t0
  T_WAITING=0
  jstep stopping
  T_CODE=AP-515; T_WHY="the gateway could not be stopped"
  svc_stop stop-gateway alphapool-gateway-start.service datum-gateway.service || return 1
  if [ "$T_K" = 1 ]; then
    T_WHY="the node could not be stopped"
    svc_stop stop-node knots-node.service || return 1
  fi
  jstep switching
  T_CODE=AP-503; T_WHY="the new programs could not be made the active set (is the disk full?)"
  set_switch "$T_NEW" || return 1
  fault switched
  set_links "$T_K" "$T_G" || return 1
  set_state "$T_NEW"
  jstep switched
  if [ "$T_K" = 1 ]; then
    T_CODE=AP-511; T_WHY="the new Bitcoin Knots did not start on this server"
    log0=$(node_log_size); t0=$(date +%s)
    svc_start start-node knots-node.service || return 1
    say_t "  the new Bitcoin Knots is in place: waiting for the node to come up"
    if ! node_comes_up; then
      if node_refused_snapshot "$log0" "$t0"; then T_CODE=AP-414; T_WHY=$REFUSED_WHY; fi      # the reason, in plain words, when the node gave it
      return 1
    fi
    fault node-up && return 1
    is_dry || runs_from knots-node.service bitcoind || return 1      # an answer from a process that never stopped does not count
    say_t "  the node is up: $(knots_label), block $(cli getblockcount 2>/dev/null || echo '?')"
  fi
  jstep node-up
  T_CODE=AP-512; T_WHY="the DATUM gateway did not come back after the upgrade"
  [ "$T_G" = 1 ] && T_WHY="the new DATUM gateway did not start on this server"
  svc_start start-gateway alphapool-gateway-start.service || return 1
  gw_settles; r=$?
  case $r in 0) ;; 2) T_WAITING=1;; *) return 1;; esac
  jstep gateway-up
  return 0
}
txn_commit(){   # the new set runs: it is the installed software now, the one before it is the way back
  fault commit
  TXN_OPEN=0
  kv_set "$STATE" previous_set "$T_OLD"; kv_set "$STATE" upgraded_at "$(date -u +%FT%TZ)"
  [ -z "$T_MODE" ] || [ ! -w "$CONF" ] || kv_set "$CONF" START_MODE "$T_MODE"        # the start mode you asked for is the node's mode from now on
  rm -f "$JOURNAL"; sync "$ETC" 2>/dev/null
  rm -rf "$RB"
  set_prune
  write_versions
}
# txn_rollback: the set from before becomes the active one again and everything is started. It never calls die.
# 0 = the previous programs are active and came up again. 1 = not confirmed: T_RB says what is known.
txn_rollback(){
  local bad=0 r
  TXN_OPEN=0; T_RB=""
  txn_pending && jstep rollback
  run systemctl stop alphapool-gateway-start.service datum-gateway.service
  if [ -n "$T_OLD" ] && [ "$(active_set || true)" != "$T_OLD" ]; then
    if fault rb-switch || ! set_switch "$T_OLD"; then
      T_RB="The previous programs could NOT be made the active set again. The journal is kept: the next start of this server, or the next run of the installer, tries again."
      say "  $T_RB"
      run systemctl start knots-node.service; run systemctl start alphapool-gateway-start.service      # whatever is active: better than nothing running
      return 1
    fi
  fi
  [ -n "$T_OLD" ] && set_state "$T_OLD"
  if [ "$T_K" = 1 ]; then
    if is_dry || ! runs_from knots-node.service bitcoind; then
      run systemctl stop knots-node.service
      svc_start rb-start-node knots-node.service || bad=1
    fi
    node_comes_up || bad=1
  fi
  if svc_start rb-start-gateway alphapool-gateway-start.service; then gw_settles; r=$?; [ $r -eq 1 ] && bad=1; else bad=1; fi
  rm -f "$JOURNAL"; sync "$ETC" 2>/dev/null
  set_prune; write_versions
  if [ $bad = 0 ]; then say_t "  the programs from before are active and running again: $(knots_label), gateway $(gw_label)"
  else T_RB="The programs from before are the active set again, but the node or the gateway had not come up when this ended."; say "  $T_RB"; fi
  return $bad
}
# txn_run KDIR GDIR: freshly staged, verified programs ("" = that component stays) become the running programs, or
# nothing changes. Everything that can fail without stopping a service comes first.
txn_run(){
  T_K=0; T_G=0; T_WAITING=0
  [ -n "$1" ] && T_K=1
  [ -n "$2" ] && T_G=1
  set_adopt "$T_K" "$T_G" || die AP-503 "the programs installed now could not be saved as the way back (is the disk full?). Nothing was changed."
  T_OLD=$OLD_SET
  set_make "${1:-keep}" "${2:-keep}" && [ -n "$SET_ID" ] || die AP-503 "the new programs could not be put in a directory of their own (is the disk full?). Nothing was changed."
  T_NEW=$SET_ID
  if [ "$T_NEW" = "$T_OLD" ]; then say "  these programs are the installed ones already"; return 0; fi
  if [ "$T_K" = 1 ] && ! snapshot_guard "$SETS/$T_NEW" pinned; then
    rm -rf "${SETS:?}/$T_NEW"
    die AP-414 "the new Bitcoin Knots build cannot run this node yet. The node started from the UTXO snapshot of block $(sg_block) and has not finished checking the history before it; the new build does not know that block${KN_HEIGHTS:+ (it knows the heights $KN_HEIGHTS)}. Upgrade when the history check is complete (alphapool-node status shows it). Nothing was changed."
  fi
  if [ "$T_G" = 1 ] && ! gw_smoke "$SETS/$T_NEW/datum_gateway"; then
    rm -rf "${SETS:?}/$T_NEW"; die AP-504 "AlphaPool's gateway binary does not run on this server. Nothing was changed."
  fi
  write_resume_unit                              # a restart of the server in the middle must find the way to finish
  [ "$WM_RESULT" != kept ] || warn "you edited alphapool-install-resume.service: after a power cut in the middle of the upgrade, run: sudo alphapool-node upgrade"
  T_GW_RAN=0                                     # did the gateway run before this upgrade? Its own service says so
  if is_dry; then T_GW_RAN=${AP_DRY_NODE_SYNCED:-1}; elif [ "$(unit_state datum-gateway.service)" = active ]; then T_GW_RAN=1; fi
  sync        # both sets, this installer's copy and the resume unit are on the disk before the journal says "an upgrade is in flight"
  journal_write prepared || die AP-503 "the upgrade journal could not be written (is the disk full?). Nothing was changed."
  TXN_OPEN=1
  say_t "  stopping the gateway$([ "$T_K" = 1 ] && echo ', then the node') (your rigs reconnect by themselves afterwards)"
  if txn_forward; then
    txn_commit
    return 0
  fi
  say_t "  $T_WHY: putting the previous programs back"
  if txn_rollback; then
    die "$T_CODE" "$T_WHY, so the programs from before were put back and are running again. Nothing else was changed. (Why: alphapool-node logs node, alphapool-node logs gateway.)"
  fi
  die "$T_CODE" "$T_WHY. $T_RB (alphapool-node status shows what runs.)"
}
# txn_recover: a journal is there, so an upgrade was cut short (a crash, kill -9, a power cut, a reboot). The new
# set was complete and verified before the journal was written. The upgrade is finished from the journal; if the new
# set is damaged, or its programs do not come up, the previous set is put back.
# 0 = finished: the new set runs. 1 = the previous set is active and runs again. 2 = not confirmed (T_RB).
txn_recover(){
  local step
  T_OLD=$(kv_get "$JOURNAL" old || true); T_NEW=$(kv_get "$JOURNAL" new || true); step=$(kv_get "$JOURNAL" step || true)
  T_K=1; T_G=1; T_GW_RAN=1                   # an unreadable journal: assume everything was being changed
  [ "$(kv_get "$JOURNAL" knots || true)" = 0 ] && T_K=0
  [ "$(kv_get "$JOURNAL" gateway || true)" = 0 ] && T_G=0
  T_MODE=$(kv_get "$JOURNAL" mode || true)
  [ "$(kv_get "$JOURNAL" gw_ran || true)" = 0 ] && T_GW_RAN=0
  [ "$(kv_get "$JOURNAL" was_synced || true)" = 0 ] && T_GW_RAN=0      # a journal of installer 2026-10-07.2
  PHASE=upgrade
  say ""
  say_t "An upgrade of this node was cut short (at the step: ${step:-unknown}). Finishing it now."
  TXN_OPEN=1
  if [ "$step" != rollback ] && [ -n "$T_NEW" ]; then      # (set_switch checks the new set once more before it uses it)
    if txn_forward; then
      txn_commit
      say_t "  the new programs are in place: $(knots_label), gateway $(gw_label)"
      return 0
    fi
    say_t "  $T_WHY: putting the previous programs back"
  else
    say_t "  it cannot be finished from here: putting the previous programs back"
  fi
  txn_rollback && return 1
  return 2
}
mode_say(){   # the start mode of the build an upgrade moves to: said when it is not the plain case (asked for, or not builder-signed)
  [ -n "$A_START" ] || [ "$KNOTS_VERIFY" != builders ] || return 0
  say "                  start mode: $M_NAME - $M_LABEL"
  [ "$KNOTS_VERIFY" = builders ] || say "                  NOT signed by the Bitcoin Knots release builders: this build is pinned by its sha256 in this installer"
  say "                  $M_TRUST"
  [ -z "$M_TRUST_ZH" ] || say_zh "                  $M_TRUST_ZH"
}
upgrade_plan(){   # what would change -> UP_K / UP_G ("" or alphapool), one line per component. Your own builds are left alone
  local ks gs                                 # unless you asked with --knots alphapool / --gateway alphapool.
  UP_K=""; UP_G=""
  ks=$(kv_get "$STATE" knots_source || true); gs=$(kv_get "$STATE" gateway_source || true)
  if installer_is_older; then
    say "  This installer ($AP_VERSION) is older than the one this node's software came from ($(kv_get "$STATE" software_installer)): nothing to do."
    say "  Get the current command from your AlphaPool dashboard."
    return 0
  fi
  if [ -n "$MODE_GONE" ] && [ "${ks:-}" = alphapool ] && knots_untouched && [ "$A_KN" != alphapool ]; then
    say "  Bitcoin Knots : $(knots_label). This node's start mode '$MODE_GONE' is not part of this installer, so its Bitcoin Knots is left as it is."
    say "                  To move it to a start mode of this installer: alphapool-node upgrade --start NAME   ($(mode_names))"
  elif [ "${ks:-}" = alphapool ] && knots_untouched; then
    if [ "$(kv_get "$STATE" knots_pin || true)" = "$KNOTS_SHA256" ]; then say "  Bitcoin Knots : $(knots_label) - already the build this installer pins"
    else UP_K=alphapool; say "  Bitcoin Knots : $(knots_label)  ->  $KNOTS_VER (this installer's pin)"; mode_say; fi
  elif [ "$A_KN" = alphapool ]; then UP_K=alphapool; say "  Bitcoin Knots : your own build ($(knots_label))  ->  $KNOTS_VER (AlphaPool's pin, as you asked)"; mode_say
  else
    say "  Bitcoin Knots : you run your own build ($(knots_label)). The upgrade leaves it alone."
    say "                  To replace it with AlphaPool's pinned Knots $KNOTS_VER: alphapool-node upgrade --knots alphapool"
  fi
  if [ "${gs:-}" = alphapool ] && gw_untouched; then
    if [ "$(sha_u "$GW_BIN")" = "$PIN_GW_BIN" ]; then say "  DATUM gateway : $(gw_label) - already the build this installer pins"
    else UP_G=alphapool; say "  DATUM gateway : $(gw_label)  ->  release $GW_VER, sha256 ${PIN_GW_BIN:0:12}... (this installer's pin)"
      [ -z "$(gw_src)" ] || say "                  (built from the public source $GW_GIT_URL, commit ${GW_GIT_COMMIT:0:12})"; fi
  elif [ "$A_GW" = alphapool ]; then UP_G=alphapool; say "  DATUM gateway : your own build ($(gw_label))  ->  AlphaPool's release $GW_VER (as you asked)"
  else
    say "  DATUM gateway : you run your own build ($(gw_label)). The upgrade leaves it alone."
    say "                  To replace it with AlphaPool's gateway release $GW_VER: alphapool-node upgrade --gateway alphapool"
  fi
}
upgrade_apply(){   # KREQ GREQ ("" = leave it)
  local kreq=$1 greq=$2 kst="" gst=""
  work_dir
  if [ -n "$kreq" ]; then kst=$WORK/stage-knots; knots_stage "$kreq" "$kst"; fi
  if [ -n "$greq" ]; then gst=$WORK/stage-gw; gw_stage_alphapool "$gst"; fi
  txn_run "$kst" "$gst"
  [ -z "$greq" ] || GW_CHANGED=1
  return 0
}
write_versions(){
  {
    echo "installer=$AP_VERSION"
    echo "knots=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1)"
    echo "knots_sha256=$(sha_of /usr/local/bin/bitcoind)"
    echo "knots_source=$(kv_get "$STATE" knots_source || true)"
    echo "gateway_sha256=$(sha_u "$GW_BIN")"
    echo "gateway_source=$(kv_get "$STATE" gateway_source || true)"
    echo "gateway_label=$(kv_get "$STATE" gateway_label || true)"
    [ -z "$(gw_src)" ] || [ "$(sha_u "$GW_BIN")" != "$PIN_GW_BIN" ] || echo "gateway_built_from=$(gw_src)"
    echo "chain_start=$(kv_get "$STATE" chain_start || true)"
    echo "chain_start_height=$(kv_get "$STATE" chain_start_height || true)"
    echo "knots_required_ver=$KNOTS_REQUIRED_VER"
    echo "knots_required_by_height=$KNOTS_REQUIRED_BY_HEIGHT"
    echo "installer_url=$INSTALLER_URL"
  } > "$ETC/versions"
  knots_required_note
}
knots_required_note(){   # the soft-fork pin: whatever its source, the installed bitcoind must be that release in time
  [ -n "$KNOTS_REQUIRED_VER" ] || return 0
  local v; v=$(/usr/local/bin/bitcoind -version 2>/dev/null | head -1)
  case "$v" in *"$KNOTS_REQUIRED_VER"*) return 0;; esac
  warn "this bitcoind is not Bitcoin Knots $KNOTS_REQUIRED_VER, which every node must run from block $(sep "$KNOTS_REQUIRED_BY_HEIGHT") (new consensus rules). Before that block: sudo alphapool-node upgrade (AlphaPool's pin), or alphapool-node switch knots url|dir with your own build of that release"
}
# upgrade_result: what an upgrade that was carried out ends with. ONE place for every way an upgrade is carried out:
# the upgrade command, an upgrade finished from its journal after it was cut short (by the upgrade command, by the
# resume unit after a restart of the server, or by a re-run of the installer), and the upgrade a re-run of a newer
# installer makes at its end.
#   0  the new programs run (a gateway that did not run before waits for the node: said, and its starter is checked)
#   3  AP-513: the new programs are in place, but the gateway, which ran before the upgrade, is not back (UP_WAIT=1)
UP_WAIT=0
upgrade_result(){
  if [ "$T_WAITING" = 1 ] && [ "$T_GW_RAN" = 1 ]; then
    UP_WAIT=1
    printf 'upgrade-waiting AP-513 %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"; status_set "upgrade done; the gateway is not back yet"
    say ""
    say "NOTE [AP-513]: the new programs are in place and the node runs, but the gateway, which ran before the upgrade, is"
    say "not back yet: the node had not caught up with the network within $(( UPGRADE_WAIT / 60 )) minutes. UNTIL THE GATEWAY IS"
    say "BACK YOUR RIGS HAVE NO WORK FROM THIS SERVER. The gateway's starter is running and starts it by itself as soon"
    say "as the node is at the chain tip. Watch it: alphapool-node status"
    return 3
  fi
  UP_WAIT=0
  printf 'ok %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"; status_set "upgrade done"
  [ "$T_WAITING" = 0 ] || say "  the gateway did not run before the upgrade and has not started yet: it waits for the node to reach the chain tip (its starter is running)"
  return 0
}
upgrade_body(){   # the worker of --upgrade. Its result is the command's exit code: 0 done, 1 not done, 3 done but the gateway is not back
  local k g kb gb t0 i payees=0 rc
  PHASE=upgrade
  is_dry && : > "$PLAN"
  printf '\n=== AlphaPool node upgrade %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  if txn_pending; then                           # an earlier upgrade was cut short: that one first, and nothing else in this run
    status_set "finishing an upgrade that was cut short"
    txn_recover; rc=$?
    rm -f "$ETC/upgrade-request"
    if [ $rc -eq 0 ]; then upgrade_result; rc=$?; say "=== done $(date -u +%FT%TZ) ==="; return $rc; fi
    printf 'upgrade-failed AP-517 %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"; status_set "upgrade not done"
    say ""
    say "ERROR [AP-517]: the upgrade that was cut short could not be finished. ${T_RB:-The programs from before it are active and running again.}"
    say "Run the upgrade again when you are ready: sudo alphapool-node upgrade"
    return 1
  fi
  k=$(kv_get "$ETC/upgrade-request" knots || true); g=$(kv_get "$ETC/upgrade-request" gateway || true)
  T_MODE=$(kv_get "$ETC/upgrade-request" mode || true)
  if [ -n "$T_MODE" ]; then START_MODE=$T_MODE; mode_apply || die AP-105 "'$T_MODE' is not a start mode of this installer"; fi
  if [ -z "$k$g" ]; then
    rm -f "$ETC/upgrade-request"; printf 'ok %s\n' "$(date -u +%FT%TZ)" > "$ETC/last-result"
    say "Nothing to upgrade."; return 0
  fi
  status_set "upgrading the node software"
  kb=$(knots_label); gb=$(gw_label); t0=$(date +%s)
  upgrade_apply "$k" "$g"
  rm -f "$ETC/upgrade-request"
  say ""
  say "Upgrade done in $(( $(date +%s) - t0 )) s. Chain data, settings and firewall were not touched."
  if [ -n "$k" ]; then say "  Bitcoin Knots : $kb  ->  $(knots_label)"; else say "  Bitcoin Knots : $kb (unchanged)"; fi
  if [ -n "$g" ]; then say "  DATUM gateway : $gb  ->  $(gw_label)"; else say "  DATUM gateway : $gb (unchanged)"; fi
  upgrade_result; rc=$?
  [ $rc -eq 0 ] || { say "=== done $(date -u +%FT%TZ) ==="; return $rc; }
  if ! is_dry; then
    if synced "$(cli getblockchaininfo 2>/dev/null)"; then
      for i in $(seq 1 30); do
        systemctl is-active --quiet datum-gateway.service && payees=$(timeout 3 curl -sS http://127.0.0.1:7152/coinbaser 2>/dev/null | count_pool_payees "$ADDRESS")
        [ "${payees:-0}" -gt 0 ] && break
        sleep 6
      done
    fi
    if [ "${payees:-0}" -gt 0 ]; then say_t "  the gateway is connected to AlphaPool again and has a job ($payees payouts in it)"
    else say "  the gateway starts by itself once the node is at the tip: alphapool-node status"; fi
  fi
  say "=== done $(date -u +%FT%TZ) ==="
  return 0
}
upgrade_main(){
  [ "$(id -u)" = 0 ] || { echo "ERROR [AP-200]: run it as root: put sudo in front of the command"; exit 1; }
  if ! { [ -r "$CONF" ] && [ -r "$STATE" ] && [ -x /usr/local/bin/bitcoind ] && has_u -x "$GW_BIN"; }; then
    echo "ERROR [AP-210]: there is no AlphaPool node on this server to upgrade. Use the install command from your AlphaPool dashboard."; exit 1
  fi
  log_open || { echo "ERROR [AP-211]: $VAR (or $LOGD in it) is there already, but not as a directory of root's alone (it is a link, belongs to another user, or others may write to it). The installer keeps its log and its downloads there and will not use it like this. Look at it, remove it, then run again."; exit 1; }
  start_tee
  trap on_exit EXIT; trap 'exit 143' TERM HUP
  printf '\n=== AlphaPool node upgrade, installer %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  take_lock || busy                              # before anything is read or written that another run could be changing
  load_settings
  snapshot_import_guard
  network_restore
  [ -z "$A_START" ] || START_MODE=$A_START
  if ! mode_apply; then                          # the node's start mode is not in this installer: its Knots stays, unless you name a mode
    [ -z "$A_START" ] || die AP-105 "'$A_START' is not a start mode of this installer. It has: $(mode_names)."
    MODE_GONE=$START_MODE; START_MODE=$START_DEFAULT; mode_apply
  fi
  detect_os
  software_plan
  if txn_pending; then                           # settled before anything is planned: its programs are not "your own build"
    say ""
    say "An earlier upgrade of this node was cut short before it finished (a crash, a kill, a power cut)."
    say "It is finished now from its journal, or the programs from before it are put back. If you still want an"
    say "upgrade afterwards, run this command again."
    WORKER_KIND=upgrade
    launch
  fi
  say ""
  upgrade_plan
  keep_installer(){                             # `alphapool-node upgrade` and `status` use this installer from now on
    installer_is_older && return 0
    install -d -m 0755 "$LIB"
    [ "$SELF" -ef "$LIB/install.sh" ] || { install -m 0755 "$SELF" "$LIB/install.sh.new" && mv -f "$LIB/install.sh.new" "$LIB/install.sh"; }
    refresh_node_files || true
    kv_set "$STATE" installer_version "$AP_VERSION"
  }
  if [ -z "$UP_K$UP_G" ]; then
    local was; was=$(kv_get "$STATE" installer_version || true)
    keep_installer
    say ""
    [ "$was" = "$AP_VERSION" ] || installer_is_older || say "This node's helper files (the alphapool-node command, the gateway starter, the service units) are now those of installer $AP_VERSION."
    say "Nothing to upgrade."; drain; exit 0
  fi
  [ "$(free_bytes "$VAR")" -ge $(( 1000**3 )) ] && [ "$(free_bytes "$LIB")" -ge $(( 1000**3 )) ] \
    || die AP-206 "less than 1 GB of free disk: the upgrade needs room for the new programs"
  say ""
  say "Your rigs are without work for about a minute while the node restarts. Chain data and settings are not touched."
  if [ "$YES" != 1 ]; then
    if ! [ -r /dev/tty ] || ! { : < /dev/tty; } 2>/dev/null; then die AP-100 "no terminal to ask in: add --yes to run without questions"; fi
    local ans=""
    { IFS= read -r -p "Type yes to upgrade, anything else to stop: " ans < /dev/tty; } 2>/dev/tty || true
    [ "$ans" = yes ] || { say "Stopped. Nothing was changed."; drain; exit 1; }
  fi
  keep_installer
  : > "$ETC/upgrade-request"; chmod 0600 "$ETC/upgrade-request"
  kv_set "$ETC/upgrade-request" knots "$UP_K"; kv_set "$ETC/upgrade-request" gateway "$UP_G"
  local to_mode=$A_START
  [ -z "$MODE_GONE" ] || to_mode=$START_MODE          # (its old mode is not in this installer: the mode it moves to is recorded)
  [ -z "$to_mode" ] || [ -z "$UP_K" ] || kv_set "$ETC/upgrade-request" mode "$to_mode"
  WORKER_KIND=upgrade
  launch
}

# ==== the worker: steps 1-9 ============================================================================================
worker_body(){
  local was_installing=0
  PHASE=install
  install -d -m 0755 "$ETC"
  is_dry && : > "$PLAN"
  [ ! -e "$ETC/install-in-progress" ] || was_installing=1
  touch "$ETC/install-in-progress"
  printf '\n=== AlphaPool node install %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  [ -e "$STATE" ] || : > "$STATE"
  write_resume_unit                    # first, so a reboot at any later point continues the install at the next boot
  if txn_pending; then                 # an upgrade that was cut short is settled before anything else, and its outcome decides
    txn_recover; case $? in
      0) upgrade_result || true; say "  (the upgrade that was cut short is finished; the install goes on)";;
      1) say "  (the upgrade that was cut short was put back; the install goes on with the programs from before it)";;
      *) [ $was_installing = 1 ] || rm -f "$ETC/install-in-progress"        # this run installed nothing: it leaves no "install running" behind
         PHASE=upgrade; die AP-517 "an upgrade that was cut short could not be settled, so this run does not go on over it. ${T_RB:-} Look at alphapool-node status, then run: sudo alphapool-node upgrade";;
    esac
    PHASE=install
  fi
  step_packages
  step_base
  step_knots
  step_gateway
  step_chain
  step_config
  step_firewall
  step_start
  if [ -n "$UPGRADE_KNOTS$UPGRADE_GW" ]; then
    say ""; say "Upgrading to this installer's pinned software"
    PHASE=upgrade; upgrade_apply "$UPGRADE_KNOTS" "$UPGRADE_GW"; PHASE=install
    upgrade_result || true
  fi
  # the summary: now, unless a validated start is still to be made (then when its snapshot is loaded, in step 9)
  if uj_pending; then :
  elif is_dry || ! synced "$(cli getblockchaininfo 2>/dev/null)"; then summary; fi
  step_catch_up
  if [ "$READY" = 1 ] || [ "$SUMMARY_SHOWN" = 0 ]; then summary; fi
  # an upgrade was carried out in this run and the gateway, which ran before it, is still not back: the run ends as
  # the upgrade command would (AP-513, exit 3), whatever else it did
  if [ "$UP_WAIT" = 1 ] && [ "$READY" != 1 ] && { is_dry || [ "$(unit_state datum-gateway.service)" != active ]; }; then
    upgrade_result; say "=== done $(date -u +%FT%TZ) ==="; return 3
  fi
  say "=== done $(date -u +%FT%TZ) ==="
  [ "$READY" = 1 ] || handover_next_steps
  return 0
}
worker(){
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  install -d -m 0755 "$RUN"
  exec 9>"$LOCK"
  # The command that started this worker holds the lock while it prepares, and lets go once the worker exists.
  flock -w 120 9 || { echo "another AlphaPool node install or upgrade is running (alphapool-node status)"; exit 0; }
  log_open || exit 1
  exec >>"$LOG" 2>&1
  trap on_exit EXIT; trap 'exit 143' TERM HUP; trap 'exit 130' INT
  [ "$RESUMED" = 1 ] && say "(continuing after a restart of the server)"
  PHASE=install
  load_settings
  snapshot_import_guard
  network_restore
  TOKEN=$(head -c 200 "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ "$WORKER_KIND" = upgrade ] || { [ "$RESUMED" = 1 ] && [ ! -e "$ETC/install-in-progress" ]; }; then
    # An upgrade does not need the node's start mode to be one of this installer's: the Bitcoin Knots of a mode it does
    # not have is left alone (upgrade_main said so), and everything else is upgraded.
    mode_apply || { MODE_GONE=$START_MODE; START_MODE=$START_DEFAULT; }
  fi
  validate_settings
  MEM_MB=$(mem_mb); detect_os; SSH_PORTS=$(kv_get "$CONF" SSH_PORTS || echo 22); [ -n "$SSH_PORTS" ] || SSH_PORTS=22
  software_plan
  chain_present
  SELF_COPY=$LIB/install.sh
  if [ "$WORKER_KIND" = upgrade ]; then upgrade_body; return $?; fi
  if [ "$RESUMED" = 1 ] && [ ! -e "$ETC/install-in-progress" ]; then     # started at boot only for an upgrade that was cut short
    txn_pending || return 0
    upgrade_body; return $?
  fi
  worker_body
}

# ==== launching: the install runs as a systemd service, so a dropped SSH session cannot stop it ========================
follow(){   # show the worker's log from OFFSET until it finishes; its result is this command's exit code
  local off=$1 pid
  exec 1>&3 2>&4                                # stop writing into the log we are about to read
  trap 'echo; echo "It keeps running in the background. Progress: alphapool-node status   Log: $LOG"; exit 0' INT
  sleep 1
  while :; do
    pid=$(systemctl show -p MainPID --value "$INSTALL_UNIT" 2>/dev/null)
    if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
      tail -c +"$(( off + 1 ))" --pid="$pid" -f "$LOG" | terminal_output; off=$(stat -c %s "$LOG")
      continue
    fi
    # no worker process: finished, or killed and about to be started again by systemd (an upgrade is then finished from its journal)
    [ "$(unit_state "$INSTALL_UNIT.service")" = activating ] || break
    sleep 1
  done
  tail -c +"$(( off + 1 ))" "$LOG" | terminal_output
  case "$(cut -d' ' -f1 "$ETC/last-result" 2>/dev/null)" in ok) exit 0;; upgrade-waiting) exit 3;; *) exit 1;; esac
}
launch(){
  local off rc props=()
  hold_lock || busy                              # normally taken long before (take_lock); never run without it
  if is_dry || [ "$FOREGROUND" = 1 ]; then
    SELF_COPY=$SELF
    if [ "$WORKER_KIND" = upgrade ]; then upgrade_body; else worker_body; fi; rc=$?
    drain; exit "$rc"
  fi
  install -d -m 0755 "$LIB" "$RUN"
  install -m 0755 "$SELF" "$LIB/install.sh.new" && mv -f "$LIB/install.sh.new" "$LIB/install.sh"
  say ""; say "The $WORKER_KIND now runs as a background service: closing this window or losing SSH does not stop it."
  if [ "$FOLLOW" = 0 ]; then say "Progress: alphapool-node status   Log: $LOG   (web console: the login screen shows the state)"
  else say "Showing its progress (Ctrl-C stops watching, not the $WORKER_KIND):"; fi
  sleep 0.5                                      # let the log's tee write the lines above, then note where it ends
  off=$(stat -c %s "$LOG")
  systemctl reset-failed "$INSTALL_UNIT" >/dev/null 2>&1
  rm -f "$ETC/last-result"
  # An upgrade worker that is killed (kill -9, out of memory) is started again by systemd and settles the upgrade from
  # its journal. Not more than 4 times in half an hour.
  [ "$WORKER_KIND" = upgrade ] && props=(-p Restart=on-abnormal -p RestartSec=5 -p StartLimitIntervalSec=1800 -p StartLimitBurst=4)
  start_worker "${props[@]}" 2>/dev/null || start_worker || die AP-508 "could not start the $WORKER_KIND service (systemd-run)"
  exec 9>&-                                      # the worker exists and waits for the lock: hand it over
  [ "$FOLLOW" = 0 ] && { drain; exit 0; }
  follow "$off"
}
start_worker(){
  systemd-run --unit="$INSTALL_UNIT" --description="AlphaPool node $WORKER_KIND" --collect --quiet "$@" \
    /bin/bash "$LIB/install.sh" "$([ "$WORKER_KIND" = upgrade ] && echo --worker-upgrade || echo --worker)"
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
  local u p rules strat al logged=0
  log_open && logged=1                           # the log directory is checked like every directory of root's; with no usable one, nothing is logged
  is_dry || systemctl stop "$INSTALL_UNIT" alphapool-install-resume.service >/dev/null 2>&1
  exec 9>"$LOCK"
  flock -w "$(is_dry && echo 3 || echo 60)" 9 || { echo "An AlphaPool node install or upgrade is still running on this server: try again in a minute."; exit 1; }
  for u in alphapool-heartbeat.timer alphapool-heartbeat.service alphapool-gateway-start.service datum-gateway.service \
           knots-node.service datum-port-aliases.service alphapool-install-resume.service alphapool-swap.service; do
    run systemctl disable --now "$u" >/dev/null 2>&1
  done
  is_dry || systemctl stop "$INSTALL_UNIT" alphapool-snapshot-seed.service >/dev/null 2>&1
  [ -x "$LIB/port-aliases" ] && run "$LIB/port-aliases" delete
  rules=$(kv_get "$STATE" ufw_rules 2>/dev/null || true)
  if [ -n "$rules" ] && { is_dry || command -v ufw >/dev/null 2>&1; }; then
    strat=$(printf '%s' "$rules" | cut -d'|' -f2); al=$(printf '%s' "$rules" | cut -d'|' -f3)
    for p in $strat $al 8333 6881:6889; do run ufw delete allow "$p/tcp" >/dev/null 2>&1; done   # never the SSH rule
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
        /etc/issue.d/alphapool.issue /etc/issue.d/alphapool-build.issue /var/lib/alphapool-swapfile
  rm -rf "$LIB" "$DL" "$TMPD" "$VAR/seed" "$HAND" "$RUN" "$ETC"          # (the log directory in $VAR stays)
  if [ -d "$OLD_DL" ] && [ ! -L "$OLD_DL" ] && [ "$(stat -c %u -- "$OLD_DL")" = 0 ]; then rm -rf -- "$OLD_DL"; fi
  # The node user's folders are emptied by a process of the node user; root removes only what is root's: the user
  # itself and its then empty home folder (an entry of /home, which is root's).
  if id -u "$U" >/dev/null 2>&1; then
    if [ "$KEEP_CHAIN" = 1 ]; then
      as_u rm -rf "$GWD" "$HOME_U/src"
      echo "kept: the chain data in $DD (user $U). A new install on this server reuses it."
    else
      as_u find "$HOME_U" -mindepth 1 -delete 2>/dev/null
      userdel "$U" >/dev/null 2>&1
      if rmdir "$HOME_U" 2>/dev/null; then echo "removed: the node user $U and all chain data"
      else echo "removed: the node user $U and its chain data. $HOME_U was left in place: it holds files that were not the node user's own."; fi
    fi
  fi
  [ $logged = 1 ] && echo "uninstall $(date -u +%FT%TZ)" >> "$LOG"
  echo "The AlphaPool node was removed. Left in place: the system packages it installed ($PKGS) and the logs in $LOGD."
}

# ==== cloud-init / startup script ======================================================================================
sq(){ printf "'%s'" "${1//\'/\'\\\'\'}"; }
print_cloud_init(){
  local url=${CI_URL:-$INSTALLER_URL} sha args body p
  [[ $url =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=,@-]*$ ]] || { echo "ERROR [AP-130]: --installer-url is not a URL"; exit 1; }
  sha=$(sha_of "$SELF")
  args="--yes --no-follow --address $(sq "$ADDRESS")"
  [ -n "$TAG" ] && args="$args --tag $(sq "$TAG")"
  [ "$STRATUM_PORT" != 23334 ] && args="$args --stratum-port $STRATUM_PORT"
  [ -n "$ALIAS_PORTS" ] && args="$args --alias-ports $(sq "$ALIAS_PORTS")"
  [ -n "$PUBLIC_HOST" ] && args="$args --public-host $(sq "$PUBLIC_HOST")"
  # how the node gets its chain and which software it runs: exactly as asked for here (validate_choices checked them)
  [ -n "$A_START" ] && args="$args --start $A_START"
  [ -n "$A_SYNC" ] && args="$args --sync $A_SYNC"
  [ -n "$A_UTXO_URL" ] && args="$args --utxo-url $(sq "$A_UTXO_URL") --utxo-sha256 $A_UTXO_SHA --utxo-bytes $A_UTXO_BYTES"
  [ -n "$A_UTXO_HEIGHT" ] && args="$args --utxo-height $A_UTXO_HEIGHT"
  [ "$A_NO_TORRENT" = 1 ] && args="$args --no-torrent"
  [ "$A_NO_SEED" = 1 ] && args="$args --no-seed"
  [ -n "$A_KN" ] && args="$args --knots $A_KN"
  [ -n "$A_KN_URL" ] && args="$args --knots-url $(sq "$A_KN_URL")${A_KN_SHA:+ --knots-sha256 $A_KN_SHA}"
  [ -n "$A_GW" ] && args="$args --gateway $A_GW"
  [ -n "$A_GW_URL" ] && args="$args --gateway-url $(sq "$A_GW_URL") --gateway-sha256 $A_GW_SHA"
  [ -n "$A_GW_GIT" ] && args="$args --gateway-git $(sq "$A_GW_GIT") --gateway-commit $A_GW_COMMIT"
  for p in $A_SSH_PORTS; do args="$args --ssh-port $p"; done
  [ "$A_FIREWALL" = off ] && args="$args --firewall off"
  [ "$A_PORTCHECK" = off ] && args="$args --no-port-check"
  [ "$HEARTBEAT" = on ] && args="$args --node-id $NODE_ID --token-file /root/alphapool-node/heartbeat.token"
  body=$(cat <<EOS
set -u; umask 077
# its log goes where every log of the installer goes: a directory only root can enter (never under /var/log)
for p in /var/lib/alphapool /var/lib/alphapool/log; do
  mkdir "\$p" 2>/dev/null || { [ ! -L "\$p" ] && [ -d "\$p" ] && [ "\$(stat -c %u "\$p")" = 0 ] && [ \$(( 0\$(stat -c %a "\$p") & 022 )) -eq 0 ]; } || {
    for t in /dev/tty1 /dev/ttyS0; do [ -w "\$t" ] && echo "AlphaPool node: \$p is not a directory of root's alone: NOT run" > "\$t"; done
    exit 1; }
done
exec >>/var/lib/alphapool/log/cloud-init.log 2>&1
umask 022
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
    pins)      # what this installer would install on this server (alphapool-node status compares with it)
      detect_os >/dev/null 2>&1; load_settings
      mode_apply || { MODE_GONE=$START_MODE; START_MODE=$START_DEFAULT; mode_apply; }      # a node whose mode this installer does not have
      software_plan
      printf 'installer=%s\nknots_version=%s\nknots_pin=%s\ngateway_label=release %s\ngateway_pin=%s\ngateway_built_from=%s\n' \
        "$AP_VERSION" "$KNOTS_VER" "$KNOTS_SHA256" "$GW_VER" "$PIN_GW_BIN" "$(gw_src)"
      printf 'start_mode=%s\nstart_label=%s\nstart_signed=%s\nstart_about=%s\nstart_default=%s\nstart_modes=%s\nstart_gone=%s\n' \
        "$([ -n "$MODE_GONE" ] || echo "$M_NAME")" "$M_LABEL" "$M_VERIFY" "$M_ABOUT" "$START_DEFAULT" "$(mode_names)" "$MODE_GONE"
      printf 'start_trust=%s\nstart_trust_zh=%s\n' "$M_TRUST" "$M_TRUST_ZH"
      printf 'knots_required_ver=%s\nknots_required_by_height=%s\ninstaller_url=%s\n' "$KNOTS_REQUIRED_VER" "$KNOTS_REQUIRED_BY_HEIGHT" "$INSTALLER_URL"
      utxo_pick mode && printf 'utxo_height=%s\nutxo_sha256=%s\nutxo_url=%s\n' "$UX_HEIGHT" "$UX_SHA" "$UX_URL"
      exit 0;;
    upgrade) upgrade_main; exit 0;;
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
      [ -z "$A_KN_DIR$A_GW_FILE" ] || { echo "ERROR [AP-131]: --knots-dir and --gateway-file name files on THIS computer; the new server does not have them. Use --knots-url / --gateway-url, or switch after the install (alphapool-node switch ...)."; exit 1; }
      [ -z "$A_FIREWALL" ] || [ "$A_FIREWALL" = on ] || [ "$A_FIREWALL" = off ] || { echo "ERROR [AP-106]: --firewall must be on or off"; exit 1; }
      for p in $A_SSH_PORTS; do [[ $p =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "ERROR [AP-103]: --ssh-port $p is not a port"; exit 1; }; done
      [ -z "$PUBLIC_HOST" ] || host_ok "$PUBLIC_HOST" || { echo "ERROR [AP-104]: --public-host must be a host name or an IPv4 address"; exit 1; }
      validate_choices
      print_cloud_init; exit 0;;
  esac
  [ "$(id -u)" = 0 ] || { echo "ERROR [AP-200]: run it as root: put sudo in front of the command (sudo bash ap-node.sh ...)"; exit 1; }
  log_open || { echo "ERROR [AP-211]: $VAR (or $LOGD in it) is there already, but not as a directory of root's alone (it is a link, belongs to another user, or others may write to it). The installer keeps its log and its downloads there and will not use it like this. Look at it, remove it, then run again."; exit 1; }
  start_tee
  trap on_exit EXIT; trap 'exit 143' TERM HUP
  printf '\n=== AlphaPool node installer %s %s%s ===\n' "$AP_VERSION" "$(date -u +%FT%TZ)" "$(is_dry && echo ' (DRY_RUN)')"
  take_lock || busy                              # before anything is read or written that another run could be changing
  load_settings
  snapshot_import_guard
  network_restore
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
