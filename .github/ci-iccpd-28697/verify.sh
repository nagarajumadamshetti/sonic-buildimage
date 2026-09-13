#!/usr/bin/env bash
#
# Verification for sonic-net/sonic-buildimage#28697, native amd64.
#
#   1. Build the iccpd package from the merge base with master (orig) and
#      from this branch (fix), using the package's own debian/ rules.
#   2. valgrind memcheck on both builds: the base build must report the
#      uninitialised read, the fixed build must be clean.
#   3. Where the kernel allows it, the functional checks: the interfaces
#      actually bind, and the 63 and 64 character bound.
#
# The team module decides how much can run. Binding a port channel goes
# through iccp_get_port_member_list -> iccp_genric_socket_team_family_get,
# which resolves the team generic netlink family and retries in a sleep
# loop when it is missing. GitHub hosted runner kernels ship no team
# module, so iccpd blocks there during scheduler_init and no state can be
# read back. The base build never hits this, because its broken length
# check rejects every name before any bind is attempted, which is exactly
# why an empty reading proves nothing on such a host.
#
# So bind dependent assertions are skipped, loudly, when team is absent,
# rather than passing vacuously. They are covered on a host that has the
# module, where teamd creates real port channels.
#
# Every expectation that does run is asserted. Exit status is the verdict.

set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
# Where this branch left master. HEAD^ is wrong: the branch accumulates
# CI commits, so after the first one HEAD^ already contains the fix and
# the base build would be compared against itself.
BASE=${BASE:-$(git merge-base HEAD origin/master)}
WORK=$REPO/ci-work
RESULTS=$REPO/ci-results
VS_URL="https://sonic-build.azurewebsites.net/api/sonic/artifacts?branchName=master&platform=vs&target=target/docker-sonic-vs.gz"

rm -rf "$WORK" "$RESULTS"
mkdir -p "$WORK/src/orig" "$WORK/src/fix" "$RESULTS"

fail=0
skipped=0
norm() { tr ',' '\n' <<<"$1" | sed '/^$/d' | sort | paste -sd, -; }
check() { # check <description> <expected> <actual>, membership compared order independently
    if [ "$(norm "$2")" = "$(norm "$3")" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1: expected [$2], got [$3]"
        fail=1
    fi
}
skip() { echo "SKIP: $1: $2"; skipped=$((skipped + 1)); }

if sudo modprobe team 2>/dev/null; then
    HAVE_TEAM=y
    echo "team module present: port channels can bind, running the full set"
else
    HAVE_TEAM=n
    echo "no team module on $(uname -r): iccpd cannot resolve the team netlink"
    echo "family, so bind dependent checks are skipped, not asserted"
fi

echo "::group::Source trees"
echo "base: $BASE  $(git log -1 --format=%s "$BASE")"
git archive "$BASE" src/iccpd | tar -x --strip-components=2 -C "$WORK/src/orig"
git archive HEAD  src/iccpd | tar -x --strip-components=2 -C "$WORK/src/fix"
diff -ru "$WORK/src/orig" "$WORK/src/fix" | tee "$RESULTS/source-delta.txt" || true
# The base tree must still carry the defect, otherwise everything below is
# comparing the fix against itself.
if grep -q "slen > strlen(token)" "$WORK/src/orig/src/iccp_cmd.c"; then
    echo "PASS: base tree carries the original length check"
else
    echo "FAIL: base tree does not carry the original length check, BASE is wrong"
    fail=1
fi
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
if [ "$HAVE_TEAM" = n ]; then
    skip "docker-sonic-vs functional test" "needs the team module for port channels to bind"
else
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
        docker exec vs ip link show "$po" >/dev/null 2>&1 || docker exec vs config portchannel add "$po" 2>/dev/null
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
        docker exec vs bash -c "dpkg -i /tmp/iccpd-$v/iccpd_*.deb" \
            || { echo "FAIL: $v package did not install in the vs container"; fail=1; continue; }
        docker exec vs bash /usr/share/iccpd-test/start.sh
        # Keep the daemon output. docker exec -d discards it.
        docker exec -d vs bash -c 'bash /usr/share/iccpd-test/iccpd.sh > /tmp/iccpd-run.log 2>&1'
        for _ in $(seq 1 60); do docker exec vs test -S /var/run/iccpd/mclagdctl.sock && break; sleep 1; done
        if ! docker exec vs test -S /var/run/iccpd/mclagdctl.sock; then
            echo "FAIL: $v iccpd did not create its control socket. Diagnostics:"
            docker exec vs bash -c 'echo "--- installed package:"; dpkg -l iccpd 2>&1 | tail -2
                echo "--- binaries:";           ls -l /usr/bin/iccpd /usr/bin/mclagdctl 2>&1
                echo "--- iccpd.sh output:";    cat /tmp/iccpd-run.log 2>&1
                echo "--- processes:";          ps -eo pid,args | grep -E "iccpd|mclagsyncd" | grep -v grep
                echo "--- /var/log/iccpd.log:"; tail -20 /var/log/iccpd.log 2>&1
                echo "--- rendered config:";    cat /etc/iccpd/iccpd.conf 2>&1' || true
            fail=1
            continue
        fi
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
fi
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
            # Without the team module a successful parse blocks in the team
            # family lookup, so the socket may never appear. Bounded wait.
            for _ in $(seq 1 45); do [ -S /var/run/iccpd/mclagdctl.sock ] && break; sleep 1; done
            sleep 2
            state=""
            if [ -S /var/run/iccpd/mclagdctl.sock ]; then
                state=$(timeout 20 mclagdctl -i 1 dump state | sed -n "s/^MCLAG Interface: //p" | tr -d "\r")
            fi
            kill -TERM "$vg_pid" 2>/dev/null || true
            for _ in $(seq 1 20); do kill -0 "$vg_pid" 2>/dev/null || break; sleep 1; done
            kill -KILL "$vg_pid" 2>/dev/null || true
            wait "$vg_pid" 2>/dev/null || true
            cp /tmp/vg.log "/results/valgrind-$TAG.log"
            errors=$(sed -n "s/.*ERROR SUMMARY: \([0-9]*\) errors.*/\1/p" /tmp/vg.log | tail -1)
            echo "RESULT state=[$state] errors=$errors"'
}
state_of() { sed -n 's/.*state=\[\([^]]*\)\].*/\1/p' <<<"$1"; }

# Always meaningful: the defect is in the parse, which both builds reach.
out=$(run_memcheck orig 0 | tail -1); echo "orig plain: $out" | tee -a "$RESULTS/memcheck.txt"
check "memcheck, base build reports the uninitialised read" "errors=1" "${out##* }"
grep -q "iccp_cmd.c:138" "$RESULTS/valgrind-orig-0.log" \
    && echo "PASS: the error is at iccp_cmd.c:138" \
    || { echo "FAIL: base build error is not at iccp_cmd.c:138"; fail=1; }

out=$(run_memcheck fix 0 | tail -1); echo "fix plain: $out" | tee -a "$RESULTS/memcheck.txt"
check "memcheck, fixed build is clean" "errors=0" "${out##* }"

if [ "$HAVE_TEAM" = n ]; then
    skip "fixed build binds both PortChannels" "needs the team module"
    skip "bound, 63 characters accepted"       "acceptance is only observable through a bind"
    skip "bound, 64 characters rejected"       "indistinguishable from a blocked bind without team"
else
    check "memcheck, fixed build binds both" "PortChannel0002,PortChannel0001" "$(state_of "$out")"

    out=$(run_memcheck fix 63 | tail -1); echo "fix 63: $out" | tee -a "$RESULTS/memcheck.txt"
    check "bound, 63 characters accepted" "PortChannel0001" "$(state_of "$out")"

    out=$(run_memcheck fix 64 | tail -1); echo "fix 64: $out" | tee -a "$RESULTS/memcheck.txt"
    check "bound, 64 characters rejected" "" "$(state_of "$out")"
fi
echo "::endgroup::"

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: passed. Bug reproduced on the base build and gone on this branch."
    [ "$skipped" -gt 0 ] && echo "         $skipped bind dependent checks skipped, see notes above."
else
    echo "VERDICT: one or more checks failed"
fi
exit "$fail"
