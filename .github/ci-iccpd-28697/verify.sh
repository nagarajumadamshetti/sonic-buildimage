#!/usr/bin/env bash
#
# Verification for sonic-net/sonic-buildimage#28697, native amd64.
#
#   1. Build the iccpd package from the base commit (orig) and from this
#      branch (fix), using the package's own debian/ rules.
#   2. Functional check on the official docker-sonic-vs image, driven by
#      the stock docker-iccpd start.sh, iccpd.j2 and iccpd.sh.
#   3. valgrind memcheck, plus the 63 and 64 character bound.
#
# PortChannel netdevs: GitHub runners have no team module (the kernel
# ships none), so teamd cannot create PortChannels there. iccpd decides
# interface type from a name prefix whitelist in iccp_netlink.c, with no
# link kind check, so a dummy netdev named PortChannel0001 is treated as
# a port channel exactly like a team device. When team is present the
# script uses the real teamd path through "config portchannel add", and
# falls back to dummy netdevs otherwise. The teamd path is covered on a
# host that has the module.
#
# Every expectation is asserted. Exit status is the verdict.

set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
BASE=${BASE:-$(git rev-parse HEAD^)}
WORK=$REPO/ci-work
RESULTS=$REPO/ci-results
VS_URL="https://sonic-build.azurewebsites.net/api/sonic/artifacts?branchName=master&platform=vs&target=target/docker-sonic-vs.gz"

rm -rf "$WORK" "$RESULTS"
mkdir -p "$WORK/src/orig" "$WORK/src/fix" "$RESULTS"

fail=0
norm() { tr ',' '\n' <<<"$1" | sed '/^$/d' | sort | paste -sd, -; }
check() { # check <description> <expected> <actual>, membership compared order independently
    if [ "$(norm "$2")" = "$(norm "$3")" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1: expected [$2], got [$3]"
        fail=1
    fi
}

echo "::group::Source trees"
git archive "$BASE" src/iccpd | tar -x --strip-components=2 -C "$WORK/src/orig"
git archive HEAD  src/iccpd | tar -x --strip-components=2 -C "$WORK/src/fix"
diff -ru "$WORK/src/orig" "$WORK/src/fix" | tee "$RESULTS/source-delta.txt" || true
echo "::endgroup::"

echo "::group::Build iccpd packages"
# Bookworm matches the docker-sonic-vs runtime (Debian 12, libnl 3.7.0).
docker build -t iccpd-builder - <<'DOCKERFILE'
FROM debian:bookworm
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential debhelper dh-exec autotools-dev autoconf automake libtool \
      pkg-config fakeroot valgrind iproute2 procps \
      libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libnl-cli-3-dev \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

for v in orig fix; do
    mkdir -p "$WORK/out/$v"
    docker run --rm -v "$WORK/src/$v:/src:ro" -v "$WORK/out/$v:/out" iccpd-builder bash -ec '
        cp -a /src /build && cd /build
        dpkg-buildpackage -rfakeroot -b -us -uc -j"$(nproc)" > /out/build.log 2>&1 \
            || { tail -40 /out/build.log; exit 1; }
        cp ../*.deb /out/'
    echo "$v: $(cd "$WORK/out/$v" && ls iccpd_*.deb)"
done
echo "::endgroup::"

echo "::group::docker-sonic-vs functional test"
if sudo modprobe team 2>/dev/null; then
    HAVE_TEAM=y
    echo "team module present, PortChannels come from teammgrd"
else
    HAVE_TEAM=n
    echo "NOTE: no team module on $(uname -r), PortChannels created as dummy netdevs"
fi

curl -fL --retry 3 -sS -o "$WORK/docker-sonic-vs.gz" "$VS_URL"
docker load -i "$WORK/docker-sonic-vs.gz"

docker rm -f sw vs >/dev/null 2>&1 || true
docker run -d --name sw debian:bookworm-slim sleep infinity >/dev/null
sudo bash "$REPO/platform/vs/create_vnet.sh" -n 2 sw
docker run --privileged --network container:sw --name vs -d docker-sonic-vs:latest >/dev/null

for _ in $(seq 1 150); do
    if docker exec vs supervisorctl status 2>/dev/null | grep -q "orchagent .*RUNNING" \
       && docker exec vs redis-cli -n 0 exists PORT_TABLE:PortInitDone 2>/dev/null | grep -q 1; then break; fi
    sleep 4
done
docker exec vs show version | grep "SONiC Software Version" | tee "$RESULTS/vs-version.txt"

for po in PortChannel0001 PortChannel0002; do
    if docker exec vs ip link show "$po" >/dev/null 2>&1; then continue; fi
    if [ "$HAVE_TEAM" = y ]; then
        docker exec vs config portchannel add "$po" 2>/dev/null
    else
        docker exec vs ip link add "$po" type dummy
    fi
done
for _ in $(seq 1 30); do docker exec vs ip link show PortChannel0002 >/dev/null 2>&1 && break; sleep 1; done
docker exec vs ip -br link show | grep PortChannel | tee "$RESULTS/vs-portchannels.txt"

docker exec vs redis-cli -n 4 hset "MC_LAG|1" local_ip 10.0.0.0 peer_ip 10.0.0.1 \
    peer_link Ethernet4 mclag_interface "PortChannel0001,PortChannel0002" >/dev/null

docker exec vs mkdir -p /usr/share/iccpd-test /var/run/iccpd
for f in start.sh iccpd.sh; do docker cp "$REPO/dockers/docker-iccpd/$f" "vs:/usr/share/iccpd-test/$f"; done
docker cp "$REPO/dockers/docker-iccpd/iccpd.j2" vs:/usr/share/sonic/templates/iccpd.j2

for v in orig fix; do
    docker exec vs bash -c 'pkill -9 -f "^bash /usr/share/iccpd-test/iccpd.sh"; pkill -9 -x mclagsyncd; pkill -9 -x iccpd; true'
    docker exec vs rm -f /var/run/iccpd/mclagdctl.sock
    docker cp "$WORK/out/$v/." "vs:/tmp/iccpd-$v/"
    docker exec vs bash -c "dpkg -i /tmp/iccpd-$v/iccpd_*.deb >/dev/null"
    docker exec vs bash /usr/share/iccpd-test/start.sh
    docker exec -d vs bash /usr/share/iccpd-test/iccpd.sh
    for _ in $(seq 1 60); do docker exec vs test -S /var/run/iccpd/mclagdctl.sock && break; sleep 1; done
    sleep 3
    state=$(docker exec vs mclagdctl -i 1 dump state | sed -n 's/^MCLAG Interface: //p' | tr -d '\r')
    echo "$v: MCLAG Interface: [$state]" | tee -a "$RESULTS/sonic-vs.txt"
    if [ "$v" = orig ]; then
        check "docker-sonic-vs, base build binds nothing" "" "$state"
    else
        check "docker-sonic-vs, fixed build binds both PortChannels" "PortChannel0002,PortChannel0001" "$state"
    fi
done
docker rm -f sw vs >/dev/null 2>&1 || true
echo "::endgroup::"

echo "::group::valgrind and bound"
run_memcheck() { # run_memcheck <variant> <token length, or 0 for the plain config>
    local v=$1 len=$2 tag=$1-${2}
    docker run --rm --cap-add NET_ADMIN -v "$WORK/out/$v:/debs:ro" -v "$RESULTS:/results" \
        -e LEN="$len" -e TAG="$tag" iccpd-builder bash -ec '
            dpkg -i /debs/iccpd_*.deb /debs/iccpd-dbg_*.deb >/dev/null
            for pc in PortChannel0001 PortChannel0002; do
                ip link add "$pc" type team 2>/dev/null || ip link add "$pc" type dummy
            done
            ip link add Ethernet4 type dummy
            mkdir -p /var/run/iccpd /etc/iccpd

            if [ "$LEN" = 0 ]; then
                ifaces="PortChannel0001,PortChannel0002"
            else
                token=PortChannel
                while [ ${#token} -lt "$LEN" ]; do token="${token}x"; done
                ifaces="$token,PortChannel0001"
            fi
            cat > /etc/iccpd/iccpd.conf <<EOF
mclag_id:1
    local_ip:10.0.0.0
    peer_ip:10.0.0.1
    peer_link:Ethernet4
    mclag_interface:$ifaces
system_mac:52:54:00:12:34:56
EOF
            valgrind --track-origins=yes --log-file=/tmp/vg.log /usr/bin/iccpd -c >/tmp/iccpd.log 2>&1 &
            vg_pid=$!
            for _ in $(seq 1 90); do [ -S /var/run/iccpd/mclagdctl.sock ] && break; sleep 1; done
            sleep 2
            state=$(timeout 20 mclagdctl -i 1 dump state | sed -n "s/^MCLAG Interface: //p" | tr -d "\r")
            kill -TERM "$vg_pid" 2>/dev/null || true
            for _ in $(seq 1 20); do kill -0 "$vg_pid" 2>/dev/null || break; sleep 1; done
            kill -KILL "$vg_pid" 2>/dev/null || true
            wait "$vg_pid" 2>/dev/null || true
            cp /tmp/vg.log "/results/valgrind-$TAG.log"
            errors=$(sed -n "s/.*ERROR SUMMARY: \([0-9]*\) errors.*/\1/p" /tmp/vg.log | tail -1)
            echo "RESULT state=[$state] errors=$errors"'
}

# Compare the interface list itself. The bracketed form does not survive
# the order independent comparison in check().
state_of() { sed -n 's/.*state=\[\([^]]*\)\].*/\1/p' <<<"$1"; }

out=$(run_memcheck orig 0 | tail -1); echo "orig plain: $out" | tee -a "$RESULTS/memcheck.txt"
check "memcheck, base build reports one error"  "errors=1" "${out##* }"
check "memcheck, base build binds nothing"      "" "$(state_of "$out")"

out=$(run_memcheck fix 0 | tail -1); echo "fix plain: $out" | tee -a "$RESULTS/memcheck.txt"
check "memcheck, fixed build is clean"          "errors=0" "${out##* }"
check "memcheck, fixed build binds both"        "PortChannel0002,PortChannel0001" "$(state_of "$out")"

out=$(run_memcheck fix 63 | tail -1); echo "fix 63: $out" | tee -a "$RESULTS/memcheck.txt"
check "bound, 63 characters accepted"           "PortChannel0001" "$(state_of "$out")"

out=$(run_memcheck fix 64 | tail -1); echo "fix 64: $out" | tee -a "$RESULTS/memcheck.txt"
check "bound, 64 characters rejected"           "" "$(state_of "$out")"
echo "::endgroup::"

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: bug reproduced on the base build and fixed on this branch"
else
    echo "VERDICT: one or more checks failed"
fi
exit "$fail"
