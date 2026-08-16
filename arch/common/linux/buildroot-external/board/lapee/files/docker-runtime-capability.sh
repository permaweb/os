# This file is sourced by the generic LapEE capability runner. It is installed
# only in the explicit measured Docker profile.
case "$LAPEE_CAPABILITY_PHASE" in
    boot-input)
        [ "$(cmdline_value lapee.docker || true)" = "enabled" ] || \
            halt_boot "Docker runtime is present without its measured activation"
        _docker_input=$LAPEE_CAPABILITY_INPUT_ROOT/EFI/boot/docker-image.tar
        if [ -f "$_docker_input" ]; then
            _docker_input_bytes=$(wc -c < "$_docker_input" 2>/dev/null | tr -d ' ')
            case "$_docker_input_bytes" in
                ''|*[!0-9]*)
                    halt_boot "could not size the operator Docker image"
                    ;;
            esac
            if [ "$_docker_input_bytes" -lt 1 ] || \
               [ "$_docker_input_bytes" -gt 536870912 ]; then
                halt_boot "operator Docker image is outside the 512 MiB input bound"
            fi
            mkdir -p /run/lapee/capability-input
            cp "$_docker_input" /run/lapee/capability-input/docker-image.tar \
                || halt_boot "could not copy the operator Docker image"
            chmod 600 /run/lapee/capability-input/docker-image.tar
            trace "docker: copied operator image archive before boot-media detach"
        fi
        ;;
    activate)
        [ "$(cmdline_value lapee.docker || true)" = "enabled" ] || \
            halt_boot "Docker runtime is present without its measured activation"
        for _docker_binary in docker dockerd containerd \
                containerd-shim-runc-v2 runc tini; do
            command -v "$_docker_binary" >/dev/null 2>&1 || \
                halt_boot "Docker profile is missing $_docker_binary"
        done

        mkdir -p /sys/fs/cgroup
        if ! grep -q ' /sys/fs/cgroup cgroup2 ' /proc/mounts 2>/dev/null; then
            mount -t cgroup2 -o nosuid,noexec,nodev cgroup2 /sys/fs/cgroup || \
                halt_boot "could not mount the Docker cgroup hierarchy"
        fi
        [ -r /proc/swaps ] || halt_boot "could not inspect host swap state"
        if awk 'NR > 1 { active = 1 } END { exit(active ? 0 : 1) }' \
                /proc/swaps; then
            halt_boot "Docker execution requires host swap to remain disabled"
        fi

        _docker_root=/run/lapee/docker-runtime
        mkdir -p "$_docker_root"
        mount -t tmpfs -o nosuid,nodev,mode=0700,size=4096m \
            docker-runtime "$_docker_root" || \
            halt_boot "could not mount the bounded Docker runtime"
        mkdir -p "$_docker_root/data" "$_docker_root/exec" \
            "$_docker_root/state" "$_docker_root/members" \
            "$_docker_root/transfer"
        chmod 700 "$_docker_root" "$_docker_root/data" \
            "$_docker_root/exec" "$_docker_root/state" \
            "$_docker_root/members" "$_docker_root/transfer"

        _docker_socket=$_docker_root/state/engine.sock
        # LapEE runs directly from initramfs `rootfs`, which Linux cannot use
        # as the old root of pivot_root(2). Moby maps this documented ramdisk
        # marker to runc's NoPivotRoot option for every container.
        DOCKER_RAMDISK=1 /usr/bin/dockerd \
            --host "unix://$_docker_socket" \
            --data-root "$_docker_root/data" \
            --exec-root "$_docker_root/exec" \
            --pidfile "$_docker_root/state/engine.pid" \
            --storage-driver overlay2 \
            --icc=false \
            --userland-proxy=false \
            --log-level error \
            > "$_docker_root/state/engine.log" 2>&1 &
        _docker_pid=$!
        DOCKER_HOST="unix://$_docker_socket"
        export DOCKER_HOST

        _docker_ready=0
        for _docker_try in 1 2 3 4 5 6 7 8 9 10 \
                11 12 13 14 15 16 17 18 19 20 \
                21 22 23 24 25 26 27 28 29 30 \
                31 32 33 34 35 36 37 38 39 40 \
                41 42 43 44 45 46 47 48 49 50 \
                51 52 53 54 55 56 57 58 59 60; do
            if ! kill -0 "$_docker_pid" 2>/dev/null; then
                break
            fi
            if /usr/bin/docker info >/dev/null 2>&1; then
                _docker_ready=1
                break
            fi
            sleep 1
        done
        if [ "$_docker_ready" != "1" ]; then
            while IFS= read -r _docker_line; do
                trace "docker: $_docker_line"
            done < "$_docker_root/state/engine.log"
            halt_boot "private Docker Engine did not become ready"
        fi
        chmod 600 "$_docker_socket"

        _docker_archive=/run/lapee/capability-input/docker-image.tar
        if [ -f "$_docker_archive" ]; then
            if ! /usr/bin/docker load --input "$_docker_archive" \
                    > "$_docker_root/state/image-load.log" 2>&1; then
                rm -f "$_docker_archive"
                halt_boot "could not load the operator Docker image"
            fi
            rm -f "$_docker_archive"
            trace "docker: operator image loaded and input archive deleted"
        fi
        trace "docker: private Unix-socket engine ready"
        ;;
    *)
        halt_boot "unknown capability hook phase"
        ;;
esac
