#!/usr/bin/env bash
# VPSKIT_SINGLE_FILE - MIT License - Copyright (c) 2026 VPSKit contributors
# VPSKit 1.1.0 | Debian 12+, Ubuntu 18.04+, systemd, amd64/arm64, Bash 4.4+.
# 单文件交付；运行配置/上游程序/证书在 /opt/vpskit；不创建系统账户。
# 使用: sudo bash vpskit.sh ; 安装后: sudo vpskit
# 上传为 biao169/hijkpw-scripts-mod/main/vpskit.sh 后:
# bash <(curl -fsSL https://raw.githubusercontent.com/biao169/hijkpw-scripts-mod/main/vpskit.sh)
# Root安装及服务运行。现有外部程序不接管、不卸载；不自动修改防火墙。
# 支持: VLESS REALITY/Vision、VMess/VLESS/Trojan WS+TLS或TCP+TLS、Shadowsocks AEAD/2022。
# 不声称支持Xray所有实验协议、传输或客户端。配置修改可能重启Xray并中断连接。
# 完整卸载删除本工具资料；系统共享依赖仅在检查无其他依赖后可选移除。
# 真实域名ACME、云安全组及实际网络吞吐必须在目标VPS验收。

# jq filters and Nginx variables below deliberately use literal single quotes.
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
VERSION='1.1.0'
XRAY_TESTED_VERSION='v26.3.27'
ROOT='/opt/vpskit'
ENTRY='/usr/local/bin/vpskit'
STATE="$ROOT/data/state.json"
SELF_URL='https://raw.githubusercontent.com/biao169/hijkpw-scripts-mod/main/vpskit.sh'
SYSTEMD='/etc/systemd/system'
SYSCTL_LINK='/etc/sysctl.d/90-vpskit.conf'
XRAY="$ROOT/bin/xray"
NGINX="$ROOT/nginx/usr/sbin/nginx"
ACME="$ROOT/acme/acme.sh"
NO_COLOR_FLAG=0
TX=0
PANEL_IDLE=0
UNINSTALLING=0
WORK=''
LOCK_FD=''
HAVE_LOCK=0
TTY_FD=''
LOGFILE=''
RED='' GREEN='' YELLOW='' BLUE='' RESET=''

author_note() { printf '%s\n' 'VPSKit: 本地管理工具，不修改SSH、不创建用户、不清空防火墙。'; }
colors() {
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} && $NO_COLOR_FLAG == 0 ]]; then
        RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; RESET=$'\033[0m'
    fi
}
log() {
    local level=$1 color=$2; shift 2
    printf '%s[%s] [%s] %s%s\n' "$color" "$(date '+%F %T')" "$level" "$*" "$RESET" >&2
    if [[ -n $LOGFILE && -d ${LOGFILE%/*} ]]; then
        printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >> "$LOGFILE"
    fi
}
info() { log INFO "$BLUE" "$@"; }
ok() { log OK "$GREEN" "$@"; }
warn() { log WARN "$YELLOW" "$@"; }
die() { log ERROR "$RED" "$@"; exit 1; }
run() {
    # Do not pass credentials to this logger; credential commands use their own output policy.
    info "执行: $1"
    if [[ -n $LOGFILE ]]; then "$@" 2>&1 | tee -a "$LOGFILE"; else "$@"; fi
}
ask() {
    local var=$1 label=$2 default=${3:-} _reply
    [[ -n $TTY_FD ]] || die '此操作需要终端。使用交互菜单，或先运行 vpskit help。'
    printf '%s%s%s' "$BLUE" "$label" "$RESET" >&2
    [[ -z $default ]] || printf ' [%s]' "$default" >&2
    printf ': ' >&2
    IFS= read -r -u "$TTY_FD" _reply || die '输入已关闭。'
    _reply=${_reply:-$default}
    printf -v "$var" '%s' "$_reply"
}
secret() {
    local var=$1 label=$2 answer
    [[ -n $TTY_FD ]] || die '需要终端输入凭据。'
    printf '%s（留空自动生成）: ' "$label" >&2
    IFS= read -r -s -u "$TTY_FD" answer || die '输入已关闭。'
    printf '\n' >&2
    printf -v "$var" '%s' "$answer"
}
confirm() {
    local answer
    ask answer "$1；输入 yes 确认" 'no'
    [[ $answer == yes ]]
}
validate_cli() {
    local cmd=${1:-menu} sub=${2:-}
    case "$cmd" in
        help|--help|-h|version|--version|explain|selftest|menu|status|doctor|repair|rollback|maintenance)
            (($#<=1)) || die '此命令不接受额外参数。';;
        install|update|uninstall|logs|site|cert|optimize) (($#<=2)) || die '额外参数不支持；参数由交互向导收集。';;
        service) (($#==3)) || die '用法: vpskit service start|stop|restart xray|nginx';;
        node)
            (($#<=3)) || die '节点参数由交互向导收集，不支持额外选项。'
            if [[ $sub == add || $sub == list ]]; then (($#<=2)) || die '用法: vpskit node add 或 node list'; fi;;
    esac
}
valid_domain() {
    local d=$1 part
    [[ ${#d} -le 253 && $d == *.* && $d != *..* && $d != .* && $d != *. ]] || return 1
    [[ $d =~ ^[a-z0-9.-]+$ && ! $d =~ ^[0-9.]+$ ]] || return 1
    local -a labels; IFS=. read -r -a labels <<< "$d"
    for part in "${labels[@]}"; do
        [[ ${#part} -le 63 && $part =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
valid_host() {
    valid_domain "$1" && return 0
    local part octets
    if [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS=. read -r -a octets <<< "$1"
        for part in "${octets[@]}"; do ((10#$part<=255)) || return 1; done
        return 0
    fi
    [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* && $1 != *:::* ]] || return 1
    # getent with AI_NUMERICHOST is unavailable in shell; use a bounded IPv6 syntax check.
    local rest=$1 doubles=0 count=0
    if [[ $rest == *::* ]]; then
        rest=${rest/::/X}; [[ $rest != *::* ]] || return 1; doubles=1
        rest=${rest/X/:}
    fi
    IFS=: read -r -a octets <<< "$rest"
    for part in "${octets[@]}"; do
        [[ -z $part ]] && continue
        [[ $part =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        count=$((count+1))
    done
    if ((doubles)); then ((count<8)); else [[ $1 != :* && $1 != *: ]] && ((count==8)); fi
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 > 0 && 10#$1 < 65536)); }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_name() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,48}$ ]]; }
valid_ws_path() { [[ $1 =~ ^/[a-zA-Z0-9_-]{8,80}$ && $1 != /\.well-known* ]]; }
valid_upstream() { [[ -z $1 || $1 =~ ^http://127\.0\.0\.1:([0-9]{1,5})$ ]] && { [[ -z $1 ]] || valid_port "${1##*:}"; }; }
new_uuid() { cat /proc/sys/kernel/random/uuid; }
randhex() { openssl rand -hex "${1:-16}"; }
get() { jq -r "$1" "$STATE"; }
json_update() {
    jq "$@" "$STATE" > "$ROOT/data/state.new"
    chmod 600 "$ROOT/data/state.new"
    mv -f "$ROOT/data/state.new" "$STATE"
}
fetch() {
    local url=$1 dest=$2
    [[ $url == https://* ]] || die '下载地址必须是HTTPS。'
    info "下载: $url"
    curl --proto '=https' --proto-redir '=https' -fSL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 2 -o "$dest" "$url"
    [[ -s $dest ]] || die '下载结果为空。'
}
check_root() { ((EUID == 0)) || die '需要root权限。请先 sudo -i，再执行一键命令；或 sudo bash ./vpskit.sh。'; }
detect_system() {
    [[ -r /etc/os-release ]] || die '无法识别系统。'
    local ID='' VERSION_ID=''
    # OS-owned metadata, never source our JSON state or user input.
    . /etc/os-release
    case "$ID" in debian) (( ${VERSION_ID%%.*} >= 12 )) || die '需要Debian 12或更新版本。';; ubuntu) (( ${VERSION_ID%%.*} >= 18 )) || die '需要Ubuntu 18.04或更新版本。';; *) die "已检测到 $ID；本版本仅支持Debian/Ubuntu，未修改系统。";; esac
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die '需要Bash 4.4或更新版本。'
    [[ -d /run/systemd/system ]] || die '需要以systemd为PID 1的VPS；不支持普通Docker/无systemd容器。'
    command -v apt-get >/dev/null || die '缺少apt-get。'
    command -v flock >/dev/null || die '需要系统自带util-linux/flock。'
    case "$(uname -m)" in x86_64) ARCH='64';; aarch64|arm64) ARCH='arm64-v8a';; *) die '仅支持amd64/arm64。';; esac
    export ARCH
    info "系统: $ID $VERSION_ID / $(uname -m)；有效账户: $(id -un)"
    [[ $(id -un) == root ]] || die '此版本只支持root安装与运行，不创建其他账户。'
}
safe_root() {
    [[ ! -L /opt && ! -L $ROOT ]] || die '安装路径为符号链接，拒绝写入。'
    if [[ -e $ROOT ]]; then
        [[ ! -L $ROOT/.vpskit-owned && -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 ]] || die "$ROOT 已存在但不属于本工具，保留并停止。"
        [[ $(stat -c %u "$ROOT") == 0 && $(stat -c %a "$ROOT") == 700 ]] || die '安装根目录必须归root所有且权限700。'
        local p
        for p in bin config data certs acme www logs backup tmp run nginx; do
            [[ ! -L $ROOT/$p ]] || die "异常符号链接: $ROOT/$p"
        done
    else
        mkdir -m 700 "$ROOT"
        printf 'VPSKIT_V1\n' > "$ROOT/.vpskit-owned"
    fi
    mkdir -p "$ROOT"/{bin,config,data,certs,acme,www,logs,backup,tmp,run,nginx}
    exec {LOCK_FD}> "$ROOT/run/manage.lock"
    flock -w 5 "$LOCK_FD" || die '另一个管理或续期任务正在运行，请稍后再试。'
    HAVE_LOCK=1
    # Only this private transient tree is disposable, never certificates/site files.
    find "$ROOT/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    WORK=$(mktemp -d "$ROOT/tmp/job.XXXXXXXX")
    LOGFILE="$ROOT/logs/manage.log"
    rotate_logs
    if [[ ! -e $ROOT/data/packages.before ]]; then
        dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$ROOT/data/packages.before"
    fi
}
rotate_logs() {
    local f
    for f in "$ROOT"/logs/*.log; do
        [[ -f $f && ! -L $f ]] || continue
        if (( $(stat -c %s "$f") > 2097152 )); then
            cp -- "$f" "$f.1"
            : > "$f"
        fi
    done
}
record_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$ROOT/data/packages.now"
    comm -13 "$WORK/packages.pre" "$ROOT/data/packages.now" > "$WORK/packages.delta"
    touch "$ROOT/data/packages.added"
    cat "$ROOT/data/packages.added" "$WORK/packages.delta" | sort -u > "$WORK/packages.union"
    mv "$WORK/packages.union" "$ROOT/data/packages.added"
}
install_deps() {
    local -a need=("$@") proposed=(); local cmd pkg d
    for cmd in curl jq openssl unzip ss free sysctl; do
        if ! command -v "$cmd" >/dev/null; then
            case "$cmd" in ss) pkg=iproute2;; free|sysctl) pkg=procps;; *) pkg=$cmd;; esac
            need+=("$pkg")
        fi
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
    ((${#need[@]})) || return 0
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' | awk '$2=="installed"{print $1}' | sort -u > "$WORK/packages.pre"
    info '预检查依赖包，拒绝包含新增系统账户操作的维护脚本。'
    run apt-get update
    local cache="$WORK/apt-cache"
    mkdir -p "$cache/partial"
    run apt-get -o "Dir::Cache::archives=$cache" --download-only --no-install-recommends -y install "${need[@]}"
    for d in "$cache"/*.deb; do
        [[ -f $d ]] || continue
        mkdir -p "$WORK/control"; dpkg-deb -e "$d" "$WORK/control"
        if grep -ERq '(^|[^[:alnum:]_])(adduser|useradd|addgroup|groupadd|systemd-sysusers)([^[:alnum:]_]|$)' "$WORK/control"; then
            die "依赖包可能创建账户，已在安装前停止: ${d##*/}。请先准备必要系统依赖。"
        fi
        rm -rf "$WORK/control"
    done
    # Install exactly downloaded versions; no second network resolution race.
    for d in "$cache"/*.deb; do [[ ! -f $d ]] || proposed+=("$d"); done
    ((${#proposed[@]})) && run apt-get --no-download --no-install-recommends -y install "${proposed[@]}"
    record_packages
    for cmd in curl jq openssl unzip ss free sysctl; do command -v "$cmd" >/dev/null || die "依赖缺失: $cmd"; done
}
init_state() {
    [[ ! -L $STATE ]] || die '状态文件不能是符号链接。'
    [[ -f $STATE ]] && { jq -e '.schema == 1 and (.nodes|type=="array") and (.sites|type=="array")' "$STATE" >/dev/null || die '状态损坏，保留资料，请恢复备份。'; return; }
    jq -n --arg version "$VERSION" '{schema:1,manager:$version,scheme:"A",host:"",performance:{gzip:false},components:{xray:false,nginx:false,acme:false},versions:{},nodes:[],sites:[]}' > "$STATE"
}

# Ubuntu 18/20 Nginx predates -e (1.19.5). Old bootstrap diagnostics go to
# stderr; configured runtime logs remain inside ROOT. Do not create /var/log/nginx.
nginx_cmd() {
    local help
    help=$("$NGINX" -h 2>&1 || true)
    local -a args=()
    [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
    "$NGINX" "${args[@]}" "$@"
}
nginx_tls_protocols() {
    local build
    build=$("$NGINX" -V 2>&1 || true)
    # Prefer the runtime OpenSSL version when Nginx reports both versions.
    if [[ $build == *'running with OpenSSL '* ]]; then build=${build##*running with OpenSSL }; else build=${build#*built with OpenSSL }; fi
    if [[ $build =~ ^(1\.1\.1|[3-9]\.) ]]; then printf 'TLSv1.2 TLSv1.3'; else printf 'TLSv1.2'; fi
}
service_runner() {
    check_root
    [[ -f $ROOT/.vpskit-owned && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 && ! -L $ROOT ]] || die '服务根目录验证失败。'
    # Bash redirection works on systemd 237; append: needs systemd 240+.
    # These internal entry points intentionally do not acquire the manager lock.
    case "$1" in
        xray) exec "$XRAY" run -config "$ROOT/config/xray.json" >> "$ROOT/logs/xray.log" 2>&1;;
        nginx-test) nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf" >> "$ROOT/logs/nginx-service.log" 2>&1;;
        nginx-reload) nginx_cmd -p "$ROOT/" -c "$ROOT/config/nginx.conf" -s reload >> "$ROOT/logs/nginx-service.log" 2>&1;;
        nginx)
            local help; help=$("$NGINX" -h 2>&1 || true)
            local -a args=(); [[ $help != *'-e filename'* ]] || args=(-e "$ROOT/logs/nginx.log")
            exec "$NGINX" "${args[@]}" -p "$ROOT/" -c "$ROOT/config/nginx.conf" -g 'daemon off;' >> "$ROOT/logs/nginx-service.log" 2>&1;;
        *) die '无效的内部服务命令。';;
    esac
}
persist_self() {
    local src=${BASH_SOURCE[0]} stage="$WORK/vpskit.sh" existing
    if [[ -f $src && $src != /dev/fd/* && $src != /proc/* ]]; then
        cp -- "$src" "$stage"
    else
        fetch "$SELF_URL" "$stage"
        grep -Fxq "VERSION='$VERSION'" "$stage" || die '远程落地版本与当前版本不同；请下载到本地后重新运行。'
    fi
    bash -n "$stage"
    grep -Fq 'VPSKIT_SINGLE_FILE' "$stage" || die '不是有效的VPSKit脚本。'
    if [[ -e $ENTRY || -L $ENTRY ]]; then
        existing=$(readlink "$ENTRY" || true)
        [[ $existing == "$ROOT/vpskit.sh" ]] || die "$ENTRY 已被其他程序使用。"
    fi
    install -m 700 "$stage" "$ROOT/vpskit.sh.new"
    mv -f "$ROOT/vpskit.sh.new" "$ROOT/vpskit.sh"
    ln -sfn "$ROOT/vpskit.sh" "$ENTRY"
}
unit_write() {
    local name=$1 path="$SYSTEMD/$1"
    [[ ! -L $path ]] || die "服务文件为符号链接: $path"
    if [[ -e $path ]]; then grep -Fq '# VPSKIT_OWNED' "$path" || die "同名外部服务存在: $path"; fi
    cat > "$path"
    chmod 644 "$path"
}
write_units() {
    unit_write vpskit-xray.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit Xray
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$ROOT
ExecStart=/bin/bash $ROOT/vpskit.sh _service xray
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
LimitNOFILE=8192
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
    unit_write vpskit-nginx.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit isolated Nginx
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=/bin/bash $ROOT/vpskit.sh _service nginx-test
ExecStart=/bin/bash $ROOT/vpskit.sh _service nginx
ExecReload=/bin/bash $ROOT/vpskit.sh _service nginx-reload
KillSignal=SIGQUIT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
    unit_write vpskit-maintain.service <<EOF
# VPSKIT_OWNED
[Unit]
Description=VPSKit certificate renewal and log maintenance
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=$ENTRY maintenance
TimeoutStartSec=30min
Nice=10
UMask=0077
EOF
    unit_write vpskit-maintain.timer <<'EOF'
# VPSKIT_OWNED
[Unit]
Description=VPSKit scheduled certificate and log check
[Timer]
OnCalendar=hourly
RandomizedDelaySec=600
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vpskit-maintain.timer
}

# Transactions contain only files owned by VPSKit. Existing websites are never snapshotted/deleted.
begin_tx() {
    ((TX == 0)) || die '禁止嵌套事务。'
    local tx="$ROOT/backup/transaction" part u
    [[ ! -e $tx ]] || die '检测到待恢复事务，请先执行 vpskit repair。'
    mkdir -p "$tx/tree" "$tx/units"
    for part in bin nginx config certs acme; do cp -a "$ROOT/$part" "$tx/tree/"; done
    cp "$STATE" "$tx/state.json"
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $SYSTEMD/$u ]]; then cp -a "$SYSTEMD/$u" "$tx/units/"; fi
        if systemctl is-active --quiet "$u"; then printf '%s\n' "$u" >> "$tx/active"; fi
        if systemctl is-enabled --quiet "$u" 2>/dev/null; then printf '%s\n' "$u" >> "$tx/enabled"; fi
    done
    : > "$tx/stopped-external"
    printf 'ready\n' > "$tx/ready"
    TX=1
}
restore_tx() {
    local tx=$1 part u failed=0
    [[ -f $tx/ready && -f $tx/state.json ]] || { warn '事务快照未完成；未替换正式配置，可清理该暂存目录。'; return 1; }
    warn '恢复操作前的程序、配置、证书和服务状态。'
    systemctl stop vpskit-xray.service vpskit-nginx.service 2>/dev/null || true
    for part in bin nginx config certs acme; do
        [[ -d $tx/tree/$part ]] || return 1
        rm -rf -- "${ROOT:?}/$part"
        cp -a "$tx/tree/$part" "$ROOT/" || failed=1
    done
    cp "$tx/state.json" "$STATE" || failed=1
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $tx/units/$u ]]; then
            cp -a "$tx/units/$u" "$SYSTEMD/$u" || failed=1
        elif [[ -e $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
            systemctl disable --now "$u" 2>/dev/null || true
            rm -f "$SYSTEMD/$u"
        fi
    done
    systemctl daemon-reload || failed=1
    for u in vpskit-xray.service vpskit-nginx.service vpskit-maintain.service vpskit-maintain.timer; do
        if [[ -e $SYSTEMD/$u ]] && { [[ ! -f $tx/enabled ]] || ! grep -Fxq "$u" "$tx/enabled"; }; then
            systemctl disable "$u" >/dev/null 2>&1 || true
        fi
    done
    if [[ -f $tx/enabled ]]; then while read -r u; do systemctl enable "$u" >/dev/null 2>&1 || failed=1; done < "$tx/enabled"; fi
    if [[ -f $tx/active ]]; then while read -r u; do systemctl start "$u" || failed=1; done < "$tx/active"; fi
    while read -r u; do [[ -z $u ]] || systemctl start "$u" || failed=1; done < "$tx/stopped-external"
    ((failed == 0))
}
commit_tx() {
    ((TX == 1)) || die '没有待提交事务。'
    rm -rf "$ROOT/backup/last"
    mv "$ROOT/backup/transaction" "$ROOT/backup/last"
    TX=0
    ok '配置已验证并提交；保留一个回滚快照。'
}
on_exit() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    if [[ $HAVE_LOCK == 1 && $PANEL_IDLE == 0 && -d $ROOT/backup/tuning-transaction ]]; then
        tuning_recover || { warn "网络调优恢复失败；保留快照，请执行 vpskit repair。"; rc=1; }
    fi
    if ((TX == 1 && UNINSTALLING == 0)); then
        if restore_tx "$ROOT/backup/transaction"; then
            rm -rf "$ROOT/backup/transaction"
        else
            warn "恢复不完整，保留 $ROOT/backup/transaction，执行 vpskit repair。"
        fi
    fi
    [[ -z $WORK || ! -d $WORK ]] || rm -rf -- "$WORK"
    if ((rc != 0)); then warn "操作未完成，退出码 $rc。现有外部网站和SSH没有被自动删除。"; fi
    exit "$rc"
}
on_error() { local rc=$1 line=$2; log ERROR "$RED" "步骤失败，行 $line，退出码 $rc（不打印可能含凭据的命令）。"; exit "$rc"; }
recover() {
    tuning_recover || die '网络调优恢复未完成，保留快照。'
    local tx="$ROOT/backup/transaction"
    if [[ -d $tx ]]; then
        if [[ ! -f $tx/ready ]]; then
            rm -rf "$tx"
            warn '清理未完成的快照；该阶段尚未变更正式配置。'
        elif restore_tx "$tx"; then
            rm -rf "$tx"; ok '已自动恢复上次中断操作。'
        else die '自动恢复失败，请检查 service 日志和事务目录。'; fi
    fi
}

# Port handling is explicit and scoped. A force kill is never a hidden side effect.
port_lines() { ss -H -lntup "sport = :$1" 2>/dev/null; }
port_free() { [[ -z $(port_lines "$1") ]]; }
protected_pid() {
    local p=$1 cur=$$ exe
    ((p > 1)) || return 0
    while ((cur > 1)); do
        [[ $p == "$cur" ]] && return 0
        cur=$(awk '/^PPid:/{print $2}' "/proc/$cur/status" 2>/dev/null || printf 1)
        [[ $cur =~ ^[0-9]+$ ]] || break
    done
    exe=$(readlink "/proc/$p/exe" 2>/dev/null || true)
    case "${exe##*/}" in sshd|systemd|init|docker*|containerd*|apt*|dpkg*|dbus-daemon|systemd-resolved) return 0;; esac
    return 1
}
pid_identity() {
    local st
    st=$(cat "/proc/$1/stat") || return 1
    printf '%s %s\n' "$(printf '%s\n' "${st##*) }" | awk '{print $20}')" "$(readlink "/proc/$1/exe")"
}
release_port() {
    local port=$1 lines p unit identity answer
    local -a pids
    lines=$(port_lines "$port")
    printf '%s\n' "$lines" >&2
    mapfile -t pids < <(printf '%s\n' "$lines" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    ((${#pids[@]})) || die '无法识别占用者；请手工处理或更换端口。'
    for p in "${pids[@]}"; do
        protected_pid "$p" && die "PID $p 为管理链路或关键服务，禁止强制清理。"
        [[ -r /proc/$p/stat ]] || continue
        identity=$(pid_identity "$p")
        unit=$(grep -oE '[^/]+\.service' "/proc/$p/cgroup" | tail -1 || true)
        if [[ -n $unit ]]; then
            case "$unit" in ssh*|systemd-*|docker*|containerd*|dbus*|vpskit-*) die "拒绝抢占关键/本工具服务 $unit；请使用相应管理功能。";; esac
            info "端口 $port 属于 $unit (PID $p)"
            confirm "停止 $unit，可能影响其现有业务" || die '已取消端口清理。'
            [[ -r /proc/$p/stat && $(pid_identity "$p") == "$identity" ]] || die '进程状态发生变化，请重试检测。'
            printf '%s\n' "$unit" >> "$ROOT/backup/transaction/stopped-external"
            systemctl stop "$unit"
        else
            warn "PID $p 不属于可恢复的systemd服务；终止后不能自动重建它。"
            confirm "向明确的PID $p 发送TERM" || die '已取消。'
            [[ -r /proc/$p/stat ]] || continue
            protected_pid "$p" && die '进程归属变化，取消清理。'
            [[ $(pid_identity "$p") == "$identity" ]] || die 'PID已重用，取消操作。'
            kill -TERM "$p"
            local tries
            for ((tries=0; tries<20; tries++)); do [[ -e /proc/$p ]] || break; sleep 0.25; done
            if [[ -e /proc/$p ]]; then
                ask answer "进程仍在运行；输入 KILL-$p 才强制终止" ''
                [[ $answer == "KILL-$p" ]] || die '未强制终止；请更换端口。'
                protected_pid "$p" && die '拒绝终止受保护进程。'
                [[ $(pid_identity "$p") == "$identity" ]] || die 'PID已重用，取消操作。'
                kill -KILL "$p"
            fi
        fi
    done
    sleep 0.3
    port_free "$port" || die "端口 $port 仍被占用；本次操作取消。"
}
check_port() {
    local port=$1 own=${2:-false} choice
    valid_port "$port" || die '端口必须为1～65535。'
    [[ $port != 22 ]] || die '不允许使用22作为代理端口。'
    if [[ $own == true ]]; then
        local pl pid all_owned=true
        pl=$(port_lines "$port")
        if [[ -z $pl ]]; then return 0; fi
        local -a owner_pids
        mapfile -t owner_pids < <(printf '%s\n' "$pl" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
        ((${#owner_pids[@]})) || all_owned=false
        for pid in "${owner_pids[@]}"; do
            if ! grep -Fq '/vpskit-nginx.service' "/proc/$pid/cgroup"; then all_owned=false; fi
        done
        [[ $all_owned != true ]] || return 0
    fi
    port_free "$port" && return 0
    warn "端口 $port 被占用（TCP/UDP、IPv4/IPv6均检查）。"
    port_lines "$port" >&2
    ask choice '1=取消并改端口，2=查看并释放明确占用者' '1'
    [[ $choice == 2 ]] || die '端口冲突，未修改服务。'
    ((TX == 1)) || die '端口释放必须处于可恢复事务中。'
    release_port "$port"
}
next_port() {
    local p=${1:-20000}
    while ((p < 65000)); do
        if port_free "$p" && ! jq -e --argjson p "$p" '.nodes[]|select(.port==$p)' "$STATE" >/dev/null; then printf '%s\n' "$p"; return; fi
        p=$((p+1))
    done
    die '没有找到可用端口。'
}

latest_release() {
    local repo=$1 out=$2
    fetch "https://api.github.com/repos/$repo/releases/latest" "$out"
    jq -er '.tag_name | select(test("^[A-Za-z0-9._-]+$"))' "$out"
}
install_xray() {
    local ver=${1:-$XRAY_TESTED_VERSION} asset url sha expected archive="$WORK/xray.zip" meta="$WORK/xray-release.json"
    case "$(uname -m)" in x86_64) asset=Xray-linux-64.zip;; aarch64|arm64) asset=Xray-linux-arm64-v8a.zip;; *) die '架构不支持。';; esac
    if [[ $ver == latest ]]; then ver=$(latest_release XTLS/Xray-core "$meta"); else
        [[ $ver =~ ^v[0-9.]+$ ]] || die 'Xray版本格式应为v数字.数字.数字。'
        fetch "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$ver" "$meta"
    fi
    url=$(jq -er --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' "$meta")
    fetch "$url" "$archive"
    expected=$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.digest // empty' "$meta")
    if [[ $expected == sha256:* ]]; then
        sha=${expected#sha256:}
    else
        fetch "$url.dgst" "$WORK/xray.dgst"
        sha=$(grep -Ei 'sha(2[-_])?256' "$WORK/xray.dgst" | grep -oE '[a-fA-F0-9]{64}' | head -1 || true)
    fi
    [[ $sha =~ ^[a-fA-F0-9]{64}$ ]] || die '没有找到有效SHA256摘要，拒绝安装。'
    printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
    unzip -p "$archive" xray > "$ROOT/bin/xray.new"
    chmod 700 "$ROOT/bin/xray.new"
    "$ROOT/bin/xray.new" version
    mv -f "$ROOT/bin/xray.new" "$XRAY"
    json_update --arg v "$ver" '.components.xray=true | .versions.xray=$v'
    ok "Xray $ver 已安装（同源摘要校验，不等同独立签名验证）。"
}
install_nginx() {
    local pkg file found=0 dir="$WORK/nginx-download" ver
    mkdir -p "$dir"
    run apt-get update
    # Extract distro's signed-repository packages, never execute nginx postinst/user creation.
    for pkg in nginx nginx-light nginx-core; do
        if ! apt-cache show "$pkg" >/dev/null 2>&1; then continue; fi
        info "下载发行版 $pkg 包，不执行维护脚本。"
        if ! (cd "$dir" && apt-get download "$pkg"); then continue; fi
        for file in "$dir"/*.deb; do
            [[ -f $file ]] || continue
            mkdir -p "$WORK/nginx-extract"
            dpkg-deb -x "$file" "$WORK/nginx-extract"
            if [[ -x $WORK/nginx-extract/usr/sbin/nginx ]]; then
                ver=$(dpkg-deb -f "$file" Version)
                found=1; break
            fi
        done
        ((found == 0)) || break
        rm -f "$dir"/*.deb
    done
    ((found == 1)) || die '发行版包中未找到Nginx二进制。'
    local soname; local -a libs=()
    while read -r soname; do
        case "$soname" in
            libpcre.so.3) libs+=(libpcre3);; libpcre2-8.so.0) libs+=(libpcre2-8-0);;
            libssl.so.1.1|libcrypto.so.1.1) libs+=(libssl1.1);;
            libssl.so.1.0.0|libcrypto.so.1.0.0) libs+=(libssl1.0.0);;
            libz.so.1) libs+=(zlib1g);; libcrypt.so.1) libs+=(libcrypt1);;
            libGeoIP.so.1) libs+=(libgeoip1);;
            *) die "未识别的Nginx共享库依赖 $soname，请用系统包管理器准备该库。";;
        esac
    done < <(ldd "$WORK/nginx-extract/usr/sbin/nginx" | awk '/not found/{print $1}')
    if ((${#libs[@]})); then install_deps "${libs[@]}"; fi
    if ldd "$WORK/nginx-extract/usr/sbin/nginx" | grep -q 'not found'; then die 'Nginx共享库仍缺失。'; fi
    mkdir -p "$ROOT/nginx/usr/sbin"
    install -m 700 "$WORK/nginx-extract/usr/sbin/nginx" "$ROOT/nginx/usr/sbin/nginx.new"
    "$ROOT/nginx/usr/sbin/nginx.new" -V
    mv -f "$ROOT/nginx/usr/sbin/nginx.new" "$NGINX"
    json_update --arg v "$ver" '.components.nginx=true | .versions.nginx=$v'
    ok "Nginx $ver 已提取到集中目录；未创建账户或系统nginx服务。"
}
install_acme() {
    local ver meta="$WORK/acme-release.json" url
    ver=$(latest_release acmesh-official/acme.sh "$meta")
    url="https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ver.tar.gz"
    fetch "$url" "$WORK/acme.tar.gz"
    mkdir -p "$WORK/acme-source" "$ROOT/acme/config" "$ROOT/acme/certstore"
    tar -tzf "$WORK/acme.tar.gz" | awk '/(^\/|(^|\/)\.\.(\/|$))/{bad=1} END{exit bad}' || die '归档路径异常。'
    tar --no-same-owner -xzf "$WORK/acme.tar.gz" --strip-components=1 -C "$WORK/acme-source"
    sh -n "$WORK/acme-source/acme.sh"
    # Run directly: no installer, profile changes, crontab, or auto-upgrade.
    install -m 700 "$WORK/acme-source/acme.sh" "$ROOT/acme/acme.sh"
    rm -rf "$ROOT/acme/dnsapi"
    cp -a "$WORK/acme-source/dnsapi" "$ROOT/acme/dnsapi"
    chmod -R go-rwx "$ROOT/acme"
    json_update --arg v "$ver" '.components.acme=true | .versions.acme=$v'
    ok "acme.sh $ver 已安装，统一由本工具timer检查续期。"
}

validate_state() {
    local n d p id mode proto credential
    jq -e '.schema==1 and (.nodes|type=="array") and (.sites|type=="array") and
      ([.nodes[].id]|length== (unique|length)) and ([.sites[].domain]|length==(unique|length))' "$STATE" >/dev/null || die '状态结构或唯一性检查失败。'
    while IFS= read -r d; do valid_domain "$d" || die '状态中的域名非法。'; done < <(jq -r '.sites[].domain' "$STATE")
    while IFS= read -r n; do
        id=$(jq -r .id <<< "$n"); p=$(jq -r .port <<< "$n")
        mode=$(jq -r .mode <<< "$n"); proto=$(jq -r .protocol <<< "$n")
        credential=$(jq -r .credential <<< "$n")
        if ! valid_name "$id" || ! valid_port "$p"; then die '节点名称或端口无效。'; fi
        case "$proto:$mode" in vless:reality|vless:ws|vless:tls|vmess:ws|vmess:ws-plain|vmess:tls|trojan:ws|trojan:tls|shadowsocks:ss) ;; *) die "不支持的协议组合: $proto/$mode";; esac
        if [[ $proto == vless || $proto == vmess ]]; then valid_uuid "$credential" || die 'UUID不合法。'; fi
        if [[ $mode == ws || $mode == tls ]]; then
            d=$(jq -r .domain <<< "$n"); valid_domain "$d" || die '节点域名不合法。'
            jq -e --arg d "$d" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null || die "节点引用了无有效证书的网站: $d"
        fi
        if [[ $mode == ws || $mode == ws-plain ]]; then valid_ws_path "$(jq -r .path <<< "$n")" || die 'WebSocket路径非法。'; fi
    done < <(jq -c '.nodes[]' "$STATE")
    jq -e '[.nodes|group_by(.entry)[] | (map(del(.id,.credential,.enabled))|unique|length)==1] | all' "$STATE" >/dev/null || die '共享入口参数不一致。'
    jq -e '[.nodes|group_by(.entry)[]|.[0].port] | length==(unique|length)' "$STATE" >/dev/null || die '不同入口的端口重复。'
}
render_xray() {
    local dest=$1
    jq --arg root "$ROOT" '
      {log:{access:"none",error:($root+"/logs/xray.log"),loglevel:"warning"},
       inbounds: ([.nodes[]|select(.enabled)] | group_by(.entry) | map(
         . as $g | .[0] as $n |
         {tag:$n.entry,listen:(if $n.mode=="ws" then "127.0.0.1" else $n.listen end),port:$n.port,protocol:$n.protocol,
          settings:(if $n.protocol=="vless" then {decryption:"none",clients:($g|map({id:.credential,email:.id,flow:(if .mode=="reality" then "xtls-rprx-vision" else "" end)}))}
            elif $n.protocol=="vmess" then {clients:($g|map({id:.credential,email:.id})),disableInsecureEncryption:true}
            elif $n.protocol=="trojan" then {clients:($g|map({password:.credential,email:.id}))}
            else {method:$n.method,password:$n.credential,network:"tcp,udp"} end)} +
          (if $n.mode=="ss" then {} else
            {streamSettings:({network:(if ($n.mode=="ws" or $n.mode=="ws-plain") then "ws" else "tcp" end),
             security:(if ($n.mode=="ws" or $n.mode=="ws-plain") then "none" elif $n.mode=="reality" then "reality" else "tls" end)} +
             (if $n.mode=="reality" then {realitySettings:{show:false,target:$n.target,xver:0,serverNames:[$n.sni],privateKey:$n.privateKey,shortIds:[$n.shortId]}}
              elif $n.mode=="tls" then {tlsSettings:{minVersion:"1.2",certificates:[{certificateFile:($root+"/certs/"+$n.domain+"/current/fullchain.pem"),keyFile:($root+"/certs/"+$n.domain+"/current/key.pem")}]}}
              else {wsSettings:{path:$n.path}} end))} end))),
       outbounds:[{tag:"direct",protocol:"freedom"},{tag:"blocked",protocol:"blackhole"}],
       routing:{domainStrategy:"IPIfNonMatch",rules:[
        {type:"field",ip:["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"],outboundTag:"blocked"}]}}
    ' "$STATE" > "$dest"
}
render_nginx() {
    local dest=$1 site domain issued upstream n path port ipv6='' protocols gzip
    protocols=$(nginx_tls_protocols)
    gzip=$(get '.performance.gzip // false')
    [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] && ipv6='yes'
    mkdir -p "$ROOT/run/nginx"/{client,proxy,fastcgi,uwsgi,scgi}
    {
        cat <<EOF
# VPSKIT_OWNED -- generated; edit sites with vpskit site, not this file.
user root;
worker_processes 1;
pid $ROOT/run/nginx.pid;
error_log $ROOT/logs/nginx.log warn;
events { worker_connections 512; }
http {
    types { text/html html htm; text/css css; application/javascript js; application/json json; image/png png; image/jpeg jpg jpeg; image/svg+xml svg; image/x-icon ico; text/plain txt; font/woff2 woff2; }
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 30;
    client_max_body_size 10m;
    access_log off;
    client_body_temp_path $ROOT/run/nginx/client;
    proxy_temp_path $ROOT/run/nginx/proxy;
    fastcgi_temp_path $ROOT/run/nginx/fastcgi;
    uwsgi_temp_path $ROOT/run/nginx/uwsgi;
    scgi_temp_path $ROOT/run/nginx/scgi;
    ssl_session_cache shared:VPSKIT:1m;
    ssl_session_timeout 10m;
    ssl_protocols $protocols;
    server {
        listen 80 default_server;
EOF
        [[ -z $ipv6 ]] || printf '        listen [::]:80 default_server;\n'
        cat <<EOF
        server_name _;
        location ^~ /.well-known/acme-challenge/ { root $ROOT/www/acme; default_type text/plain; }
        location / { return 404; }
    }
EOF
        while IFS= read -r site; do
            domain=$(jq -r .domain <<< "$site"); issued=$(jq -r .issued <<< "$site"); upstream=$(jq -r '.upstream // ""' <<< "$site")
            if ! valid_domain "$domain" || ! valid_upstream "$upstream"; then die '网站参数不合法。'; fi
            printf '    server {\n        listen 80;\n'
            [[ -z $ipv6 ]] || printf '        listen [::]:80;\n'
            printf '        server_name %s;\n' "$domain"
            printf '        location ^~ /.well-known/acme-challenge/ { root %s/www/acme; default_type text/plain; }\n' "$ROOT"
            if [[ $issued == true ]]; then
                printf '        location / { return 301 https://%s$request_uri; }\n    }\n' "$domain"
                printf '    server {\n        listen 443 ssl;\n'
                [[ -z $ipv6 ]] || printf '        listen [::]:443 ssl;\n'
                printf '        server_name %s;\n' "$domain"
                printf '        ssl_certificate %s/certs/%s/current/fullchain.pem;\n' "$ROOT" "$domain"
                printf '        ssl_certificate_key %s/certs/%s/current/key.pem;\n' "$ROOT" "$domain"
            fi
            printf '        root %s/www/%s;\n        index index.html;\n' "$ROOT" "$domain"
            printf '        location ~ /\\. { deny all; }\n'
            if [[ $issued == true ]]; then
                while IFS= read -r n; do
                    path=$(jq -r .path <<< "$n"); port=$(jq -r .port <<< "$n")
                    cat <<EOF
        location = $path {
            proxy_pass http://127.0.0.1:$port;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
EOF
                done < <(jq -c --arg d "$domain" '[.nodes[]|select(.enabled and .mode=="ws" and .domain==$d)]|unique_by(.entry)[]' "$STATE")
            fi
            if [[ -n $upstream ]]; then
                cat <<EOF
        location / {
            proxy_pass $upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
EOF
            else
                printf '        location / {\n            try_files $uri $uri/ =404;\n'
                if [[ $gzip == true ]]; then
                    cat <<'EOF'
            # Only static content; do not compress proxy payloads or dynamic secrets.
            gzip on;
            gzip_vary on;
            gzip_comp_level 2;
            gzip_min_length 1024;
            gzip_types text/plain text/css application/javascript application/json image/svg+xml;
EOF
                fi
                printf '        }\n'
            fi
            printf '    }\n'
        done < <(jq -c '.sites[]' "$STATE")
        printf '}\n'
    } > "$dest"
}
apply_config() {
    validate_state
    local xc="$ROOT/config/xray.next.json" nc="$ROOT/config/nginx.next.conf" count
    if [[ $(get .components.xray) == true ]]; then
        render_xray "$xc"
        info '验证Xray配置（验证错误可能包含本机配置路径）。'
        "$XRAY" run -test -config "$xc"
    fi
    if [[ $(get .components.nginx) == true ]]; then
        render_nginx "$nc"
        nginx_cmd -t -p "$ROOT/" -c "$nc"
    fi
    [[ ! -f $xc ]] || mv -f "$xc" "$ROOT/config/xray.json"
    [[ ! -f $nc ]] || mv -f "$nc" "$ROOT/config/nginx.conf"
    write_units
    if [[ $(get .components.nginx) == true ]]; then
        systemctl enable vpskit-nginx.service
        if systemctl is-active --quiet vpskit-nginx.service; then systemctl reload vpskit-nginx.service; else systemctl start vpskit-nginx.service; fi
        systemctl is-active --quiet vpskit-nginx.service || die 'Nginx未正常运行。'
    fi
    count=$(jq '[.nodes[]|select(.enabled)]|length' "$STATE")
    if [[ $(get .components.xray) == true && $count -gt 0 ]]; then
        warn '应用配置将重启Xray；现有代理连接可能短暂中断。'
        systemctl enable vpskit-xray.service
        systemctl restart vpskit-xray.service
        sleep 0.5
        systemctl is-active --quiet vpskit-xray.service || die 'Xray启动失败。'
        local p
        while read -r p; do
            ss -Hlnt "sport = :$p" | grep -q . || die "Xray端口$p未监听。"
        done < <(jq -r '[.nodes[]|select(.enabled)]|unique_by(.entry)[].port' "$STATE")
    else systemctl disable --now vpskit-xray.service 2>/dev/null || true; fi
}
ensure_component() {
    local c=$1
    [[ $(get ".components.$c") == true ]] || die "先安装组件: vpskit install $c"
}

# ACME: stage certs, validate matching key, switch current symlink, then reload.
acme_run() {
    "$ACME" --home "$ROOT/acme" --config-home "$ROOT/acme/config" --cert-home "$ROOT/acme/certstore" --no-color "$@"
}
site_select() {
    local dest=$1 _domain
    jq -r '.sites[]|[.domain,(if .issued then "HTTPS" else "待签发" end)]|@tsv' "$STATE" >&2
    ask _domain '域名' "$(jq -r '.sites[0].domain // ""' "$STATE")"
    valid_domain "$_domain" || die '域名不合法。'
    jq -e --arg d "$_domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null || die '找不到网站。'
    printf -v "$dest" '%s' "$_domain"
}

dns_credentials() {
    local provider=$1 token='' account='' sid='' skey=''
    # Credential values are exported only for the ACME process; acme stores them in its private account config.
    case "$provider" in
        dns_cf)
            secret token 'Cloudflare限定区域DNS编辑Token'; [[ -n $token ]] || die 'Token不能为空。'
            secret account 'Cloudflare Account ID'; [[ -n $account ]] || die 'Account ID不能为空。'
            export CF_Token="$token" CF_Account_ID="$account";;
        dns_dp)
            secret sid 'DNSPod API ID'; secret skey 'DNSPod API Key'
            [[ -n $sid && -n $skey ]] || die 'DNSPod凭据不能为空。'
            export DP_Id="$sid" DP_Key="$skey";;
        *) die '只支持Cloudflare dns_cf及DNSPod dns_dp的自动DNS验证。';;
    esac
}
cert_issue() {
    local domain=${1:-} site challenge email provider
    ensure_component acme
    [[ -n $domain ]] || site_select domain
    site=$(jq -c --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE")
    [[ -n $site ]] || die '先添加网站。'
    challenge=$(jq -r .challenge <<< "$site"); email=$(jq -r .email <<< "$site")
    local -a args=(--issue --server letsencrypt --keylength ec-256 -d "$domain" --accountemail "$email")
    if [[ $(jq -r '.wildcard // false' <<< "$site") == true ]]; then
        [[ $challenge != http ]] || die '泛域名证书必须使用DNS验证。'
        args+=(-d "*.$domain")
    fi
    if [[ $challenge == http ]]; then
        args+=(--webroot "$ROOT/www/acme")
        info "HTTP-01要求 $domain 的A/AAAA正确，公网80可达且验证路径未被CDN/WAF拦截。"
    else
        provider=$challenge
        dns_credentials "$provider"
        args+=(--dns "$provider")
    fi
    # Do not tee ACME's output to management logs (provider errors might contain sensitive context).
    local issue_rc=0
    acme_run "${args[@]}" || issue_rc=$?
    if ((issue_rc != 0 && issue_rc != 2)); then
        unset CF_Token CF_Account_ID DP_Id DP_Key
        die '签发失败，现有证书保留；核对DNS、80端口或DNS API权限。'
    fi
    unset CF_Token CF_Account_ID DP_Id DP_Key
    mkdir -p "$ROOT/certs/$domain/pending"
    acme_run --install-cert -d "$domain" --ecc --key-file "$ROOT/certs/$domain/pending/key.pem" \
        --fullchain-file "$ROOT/certs/$domain/pending/fullchain.pem" --reloadcmd /bin/true
    begin_tx
    deploy_cert "$domain"
    apply_config
    commit_tx
    ok "$domain 证书已部署，日常续期自动运行。"
}
deploy_cert() {
    local d=$1 base="$ROOT/certs/$1" cert key v prev
    cert="$base/pending/fullchain.pem"; key="$base/pending/key.pem"
    [[ -s $cert && -s $key ]] || die "$d 缺少待部署证书。"
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die '新证书有效期异常。'
    openssl x509 -in "$cert" -noout -checkhost "$d" >/dev/null || die '证书域名不匹配。'
    [[ $(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1) == \
       $(openssl pkey -in "$key" -pubout -outform DER | sha256sum | cut -d' ' -f1) ]] || die '证书和私钥不匹配。'
    v="rev-$(date +%s)-$(randhex 4)"
    mkdir -p "$base/$v"
    install -m 600 "$cert" "$base/$v/fullchain.pem"
    install -m 600 "$key" "$base/$v/key.pem"
    prev=$(readlink "$base/current" || true)
    ln -s "$v" "$base/current.new"
    mv -Tf "$base/current.new" "$base/current"
    json_update --arg d "$d" '(.sites[]|select(.domain==$d)|.issued)=true'
    [[ -z $prev ]] || info "$d 已切换证书；上次证书保存在回滚快照。"
    find "$base" -mindepth 1 -maxdepth 1 -type d -name 'rev-*' ! -name "$v" -exec rm -rf -- {} +
}
cert_renew() {
    [[ $(get .components.acme) == true ]] || return 0
    [[ $(jq '[.sites[]|select(.issued)]|length' "$STATE") -gt 0 ]] || return 0
    local rc=0 d changed=0
    if acme_run --cron; then :; else rc=$?; warn "ACME检查返回 $rc，继续核对现有证书。"; fi
    while read -r d; do
        if [[ -s $ROOT/certs/$d/pending/fullchain.pem ]] && ! cmp -s "$ROOT/certs/$d/pending/fullchain.pem" "$ROOT/certs/$d/current/fullchain.pem"; then
            if ((changed == 0)); then begin_tx; fi
            changed=1; deploy_cert "$d"
        fi
    done < <(jq -r '.sites[].domain' "$STATE")
    if ((changed)); then apply_config; commit_tx; fi
    cert_status
    return "$rc"
}
cert_status() {
    local d file bad=0
    while read -r d; do
        file="$ROOT/certs/$d/current/fullchain.pem"
        if [[ -s $file ]]; then
            printf '%s: ' "$d"; openssl x509 -in "$file" -noout -enddate
            if ! openssl x509 -in "$file" -noout -checkend 1209600 >/dev/null; then warn "$d 证书不足14天，请检查续期日志。"; bad=1; fi
        else warn "$d 尚未部署证书。"; fi
    done < <(jq -r '.sites[].domain' "$STATE")
    ((bad == 0))
}
site_add() {
    ensure_component nginx; ensure_component acme
    local domain email challenge wildcard=false wildcard_answer upstream='' own=false
    ask domain '网站域名（小写ASCII/Punycode，不含https://）' ''
    valid_domain "$domain" || die '域名格式不合法。'
    jq -e --arg d "$domain" '.sites[]|select(.domain==$d)' "$STATE" >/dev/null && die '网站已存在。'
    ask email 'ACME联系邮箱' ''
    [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die '邮箱格式不合法。'
    ask challenge '验证方式：http / dns_cf / dns_dp' http
    case "$challenge" in http|dns_cf|dns_dp);; *) die '验证方式不支持。';; esac
    if [[ $challenge != http ]]; then
        ask wildcard_answer '是否同时申请此域名的泛域名证书（域名+*.域名）？yes/no' no
        [[ $wildcard_answer != yes ]] || wildcard=true
    fi
    ask upstream '动态网站本机地址（如http://127.0.0.1:8000；留空为静态网站）' ''
    valid_upstream "$upstream" || die '只允许http://127.0.0.1:端口。'
    [[ $upstream != *:80 && $upstream != *:443 ]] || die '上游不能回指网站入口。'
    begin_tx
    if systemctl is-active --quiet vpskit-nginx.service; then own=true; fi
    check_port 80 "$own"
    check_port 443 "$own"
    mkdir -p "$ROOT/www/$domain" "$ROOT/www/acme/.well-known/acme-challenge"
    if [[ ! -e $ROOT/www/$domain/index.html ]]; then
        printf '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>%s</title><body><h1>%s</h1><p>网站已就绪。请在管理工具显示的网站目录上传内容。</p></body></html>\n' "$domain" "$domain" > "$ROOT/www/$domain/index.html"
    fi
    json_update --arg d "$domain" --arg e "$email" --arg c "$challenge" --arg u "$upstream" --argjson w "$wildcard" '.sites += [{domain:$d,email:$e,challenge:$c,upstream:$u,wildcard:$w,issued:false}]'
    apply_config
    commit_tx
    info "网站目录: $ROOT/www/$domain；接下来签发证书。签发失败可用 vpskit cert issue 重试。"
    cert_issue "$domain"
}
site_edit() {
    local domain upstream
    site_select domain
    info "网站目录: $ROOT/www/$domain；在该目录直接更新静态文件，无需重装。"
    ask upstream '新的本机动态上游；输入 static 切换为静态网站' "$(jq -r --arg d "$domain" '.sites[]|select(.domain==$d)|if .upstream=="" then "static" else .upstream end' "$STATE")"
    [[ $upstream != static ]] || upstream=''
    valid_upstream "$upstream" || die '上游格式不合法。'
    [[ $upstream != *:80 && $upstream != *:443 ]] || die '上游不能回指网站入口。'
    begin_tx
    json_update --arg d "$domain" --arg u "$upstream" '(.sites[]|select(.domain==$d)|.upstream)=$u'
    apply_config; commit_tx
}
site_remove() {
    local domain answer
    site_select domain
    jq -e --arg d "$domain" '.nodes[]|select(.domain==$d)' "$STATE" >/dev/null && die '还有节点引用此域名，请先删除这些节点。'
    confirm "移除 $domain 的站点绑定及续期（网站文件和证书另行选择删除）" || return 0
    begin_tx
    if [[ $(get .components.acme) == true ]]; then acme_run --remove -d "$domain" --ecc || die '移除续期记录失败。'; fi
    json_update --arg d "$domain" '.sites |= map(select(.domain!=$d))'
    apply_config; commit_tx
    if confirm "同时永久删除 $domain 的网站内容和证书"; then
        rm -rf -- "$ROOT/www/$domain" "$ROOT/certs/$domain"
    else ok '网站内容和证书保留在集中目录。'; fi
}

node_list() {
    printf '名称\t协议\t传输\t入口\t监听端口\t客户端端口\t状态\t域名\n'
    jq -r '.nodes[]|[.id,.protocol,(if .mode=="ws" then "WS+TLS" elif .mode=="ws-plain" then "WS(无TLS)" elif .mode=="tls" then "TCP+TLS" elif .mode=="reality" then "REALITY" else "TCP/UDP" end),.entry,(.port|tostring),(if .mode=="ws" then "443" else (.port|tostring) end),(if .enabled then "启用" else "停用" end),.domain]|@tsv' "$STATE"
}
node_select() {
    local dest=$1 n=${2:-}
    if [[ -z $n ]]; then node_list >&2; ask n '节点名称' ''; fi
    valid_name "$n" || die '节点名称不合法。'
    jq -e --arg n "$n" '.nodes[]|select(.id==$n)' "$STATE" >/dev/null || die '节点不存在。'
    printf -v "$dest" '%s' "$n"
}
choose_credential() {
    local dest=$1 protocol=$2 method=${3:-} value=''
    case "$protocol" in
        vless|vmess)
            ask value 'UUID（回车使用随机默认值）' "$(new_uuid)"
            valid_uuid "$value" || die 'UUID格式错误。';;
        shadowsocks)
            secret value "Shadowsocks密码；$method"
            if [[ -z $value ]]; then
                case "$method" in 2022-blake3-aes-128-gcm) value=$(openssl rand -base64 16);; 2022-*) value=$(openssl rand -base64 32);; *) value=$(randhex 24);; esac
            fi
            if [[ $method == 2022-* ]]; then
                local length wanted=32
                [[ $method != 2022-blake3-aes-128-gcm ]] || wanted=16
                length=$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c) || die 'SS2022密码必须是有效Base64密钥。'
                [[ $length == "$wanted" ]] || die "该SS2022方法要求Base64编码的${wanted}字节密钥。"
            fi;;
        trojan)
            secret value 'Trojan密码'
            [[ -n $value ]] || value=$(randhex 24);;
        *) die '不支持的协议。';;
    esac
    [[ ${#value} -ge 8 && ${#value} -le 256 && $value != *$'\n'* && $value != *$'\r'* ]] || die '凭据长度或字符不合法。'
    printf -v "$dest" '%s' "$value"
}
node_add() {
    ensure_component xray
    local name proto mode share entry port domain='' path='' method='' credential='' host listen target='' sni='' pk='' pub='' sid='' keys template
    ask name '节点名称（英文/数字/下划线/横线）' "node-$(randhex 3)"
    valid_name "$name" || die '节点名称格式错误。'
    jq -e --arg n "$name" '.nodes[]|select(.id==$n)' "$STATE" >/dev/null && die '名称重复。'
    node_list >&2
    ask share '复用现有入口的节点名称（留空新建入口）' ''
    if [[ -n $share ]]; then
        node_select share "$share"
        template=$(jq -c --arg n "$share" '.nodes[]|select(.id==$n)' "$STATE")
        proto=$(jq -r .protocol <<< "$template"); method=$(jq -r .method <<< "$template")
        [[ $proto != shadowsocks ]] || die 'Shadowsocks在本版本中每入口一个凭据；请新增独立端口。'
        choose_credential credential "$proto" "$method"
        jq -e --arg c "$credential" '.nodes[]|select(.credential==$c)' "$STATE" >/dev/null && die '凭据重复。'
        begin_tx
        json_update --argjson t "$template" --arg n "$name" --arg c "$credential" '.nodes += [$t|.id=$n|.credential=$c|.enabled=true]'
    else
        panel_title '选择代理协议'
        menu_item 1 'VLESS' '轻量；可选REALITY、WS+TLS、TCP+TLS'
        menu_item 2 'VMess' 'AEAD加密；可选WS、WS+TLS、TCP+TLS'
        menu_item 3 'Trojan' '密码认证；可选WS+TLS、TCP+TLS'
        menu_item 4 'Shadowsocks' '独立TCP/UDP端口；AEAD或2022方法'
        ask proto '协议编号或名称' 1
        case "$proto" in 1) proto=vless;; 2) proto=vmess;; 3) proto=trojan;; 4|ss) proto=shadowsocks;; vless|vmess|trojan|shadowsocks);; *) die '协议不支持。';; esac
        if [[ $proto == shadowsocks ]]; then mode=ss
        else
            local default=1
            [[ $(get .scheme) != A || $proto != vless ]] || default=3
            panel_title '选择传输方式（WS是传输层，不是独立代理协议）'
            menu_item 1 'WS + TLS' '推荐网站共用443；需要域名、Nginx和证书'
            menu_item 2 'TCP + TLS' '独立公网端口；需要域名和证书'
            [[ $proto != vless ]] || menu_item 3 'TCP + REALITY' '仅VLESS；独立端口，不需要自己的代理证书'
            [[ $proto != vmess ]] || menu_item 4 'WS（无外层TLS）' '仅VMess AEAD；独立端口，无HTTPS外观'
            ask mode '传输编号或名称 ws / tls / reality / ws-plain' "$default"
            case "$mode" in 1|wss|ws-tls) mode=ws;; 2) mode=tls;; 3) mode=reality;; 4) mode=ws-plain;; esac
        fi
        case "$proto:$mode" in vless:reality|vless:ws|vless:tls|vmess:ws|vmess:ws-plain|vmess:tls|trojan:ws|trojan:tls|shadowsocks:ss);; *) die '所选协议/传输组合不支持。';; esac
        if [[ $mode == ws-plain ]]; then
            warn '独立WS没有外层TLS和HTTPS伪装；VMess必须使用AEAD客户端，导出链接启用auto加密。VLESS/Trojan不提供明文WS。'
            confirm '选择VMess独立WS；通常建议改用选项1 WS+TLS' || return 0
        fi
        if [[ $mode == ws || $mode == tls ]]; then
            ensure_component nginx; site_select domain
            jq -e --arg d "$domain" '.sites[]|select(.domain==$d and .issued)' "$STATE" >/dev/null || die '此网站尚无有效证书。'
            host=$domain
        else
            ask host '客户端连接地址：VPS公网IP或直连域名（不要填写Cloudflare代理域名）' "$(get .host)"
            valid_host "$host" || die '服务器地址不合法（域名用小写，不含端口/方括号）。'
        fi
        if [[ $mode == ws ]]; then
            ask port 'Xray本机端口，客户端仍连接网站443' "$(next_port 20000)"
            ask path 'WebSocket路径（至少8个字母/数字/横线/下划线）' "/$(randhex 12)"
            valid_ws_path "$path" || die '路径格式错误。'
            jq -e --arg d "$domain" --arg p "$path" '.nodes[]|select(.domain==$d and .path==$p)' "$STATE" >/dev/null && die '路径已使用。'
            listen=127.0.0.1
        else
            local start=8443
            [[ $proto != shadowsocks ]] || start=8388
            ask port '公网代理端口（避开网站80/443和SSH）' "$(next_port "$start")"
            listen=0.0.0.0
            if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]; then listen='::'; fi
            ask listen '监听地址：0.0.0.0（IPv4）或 ::（IPv4/IPv6，需系统支持）' "$listen"
            [[ $listen == 0.0.0.0 || $listen == :: ]] || die '监听地址不支持。'
        fi
        if [[ $mode == ws-plain ]]; then
            ask path '独立WebSocket路径（至少8个字母/数字/横线/下划线）' "/$(randhex 12)"
            valid_ws_path "$path" || die '路径格式错误。'
        fi
        valid_port "$port" || die '端口错误。'; port=$((10#$port))
        [[ $port != 80 && $port != 443 ]] || die '独立入口禁止占用网站80/443；共用443请选择ws。'
        jq -e --argjson p "$port" '.nodes[]|select(.port==$p)' "$STATE" >/dev/null && die '端口已保留给已有入口（包括停用节点）。'
        if [[ $mode == reality ]]; then
            ask sni 'REALITY目标域名/SNI（应支持TLS1.3，须自行核对适用性）' www.microsoft.com
            valid_domain "$sni" || die 'SNI不合法。'
            target="$sni:443"
            local -a tls_flags=()
            local tls_help; tls_help=$(openssl s_client -help 2>&1 || true)
            if [[ $tls_help == *'-tls1_3'* ]]; then tls_flags=(-tls1_3)
            else warn '此OpenSSL不支持TLS1.3预检，仅检查证书和连通性；REALITY目标的TLS1.3能力需另行确认。'; fi
            info '检查目标TLS连接及证书。'
            timeout 15 openssl s_client -connect "$target" -servername "$sni" "${tls_flags[@]}" -verify_return_error -verify_hostname "$sni" </dev/null > "$WORK/target-check.log" 2>&1 || die '目标TLS连接失败，请更换目标。'
            keys=$("$XRAY" x25519)
            pk=$(printf '%s\n' "$keys" | awk -F': *' '/PrivateKey|Private key/{print $2;exit}')
            pub=$(printf '%s\n' "$keys" | awk -F': *' '/PublicKey|Public key|Password/{print $2;exit}')
            [[ $pk =~ ^[A-Za-z0-9_-]{43}$ && $pub =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法解析当前Xray密钥输出。'
            sid=$(randhex 8)
        fi
        if [[ $proto == shadowsocks ]]; then
            ask method '方法：aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305 / 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm' 2022-blake3-aes-128-gcm
            case "$method" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm);; *) die '加密方法不支持。';; esac
            warn 'Shadowsocks已加密，但没有REALITY/HTTPS外观；端口须放行TCP和UDP。'
        fi
        choose_credential credential "$proto" "$method"
        jq -e --arg c "$credential" '.nodes[]|select(.credential==$c)' "$STATE" >/dev/null && die '凭据重复。'
        entry="in-$(randhex 6)"
        begin_tx
        check_port "$port"
        json_update --arg id "$name" --arg entry "$entry" --arg protocol "$proto" --arg mode "$mode" \
          --argjson port "$port" --arg domain "$domain" --arg path "$path" --arg method "$method" --arg credential "$credential" \
          --arg host "$host" --arg listen "$listen" --arg target "$target" --arg sni "$sni" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" \
          '.nodes += [{id:$id,entry:$entry,protocol:$protocol,mode:$mode,port:$port,domain:$domain,path:$path,method:$method,credential:$credential,host:$host,listen:$listen,target:$target,sni:$sni,privateKey:$pk,publicKey:$pub,shortId:$sid,enabled:true}]'
    fi
    apply_config; commit_tx
    ok "节点 $name 已添加。云安全组/系统防火墙需放行对应端口；脚本未更改防火墙。"
    node_export "$name"
}
node_export() {
    local name=${1:-} n host displayhost port mode proto encoded label path sni key sid credential method
    node_select name "$name"
    n=$(jq -c --arg n "$name" '.nodes[]|select(.id==$n)' "$STATE")
    host=$(jq -r .host <<< "$n"); port=$(jq -r .port <<< "$n"); mode=$(jq -r .mode <<< "$n"); proto=$(jq -r .protocol <<< "$n")
    credential=$(jq -r .credential <<< "$n"); label=$(jq -rn --arg v "$name" '$v|@uri')
    displayhost=$host; [[ $host != *:* ]] || displayhost="[$host]"
    [[ $mode != ws ]] || port=443
    path=$(jq -r .path <<< "$n"); sni=$(jq -r '.domain' <<< "$n")
    warn '以下链接含访问凭据，请勿公开或粘贴到公共日志。'
    case "$proto" in
        vmess)
            encoded=$(jq -cn --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$credential" --arg mode "$mode" --arg path "$path" --arg sni "$sni" \
              '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:(if ($mode=="ws" or $mode=="ws-plain") then "ws" else "tcp" end),type:"none",host:$sni,path:$path,tls:(if $mode=="ws-plain" then "" else "tls" end),sni:$sni}' | base64 -w0)
            printf 'vmess://%s\n' "$encoded";;
        vless|trojan)
            local query
            if [[ $mode == reality ]]; then
                sni=$(jq -r .sni <<< "$n"); key=$(jq -r .publicKey <<< "$n"); sid=$(jq -r .shortId <<< "$n")
                query="security=reality&type=tcp&flow=xtls-rprx-vision&sni=$sni&fp=chrome&pbk=$key&sid=$sid"
            elif [[ $mode == ws ]]; then
                path=$(jq -rn --arg v "$path" '$v|@uri')
                query="security=tls&type=ws&sni=$sni&host=$sni&path=$path"
            else query="security=tls&type=tcp&sni=$sni"; fi
            [[ $proto != vless ]] || query="encryption=none&$query"
            credential=$(jq -rn --arg v "$credential" '$v|@uri')
            printf '%s://%s@%s:%s?%s#%s\n' "$proto" "$credential" "$displayhost" "$port" "$query" "$label";;
        shadowsocks)
            method=$(jq -r .method <<< "$n")
            encoded=$(printf '%s:%s' "$method" "$credential" | base64 -w0 | tr '+/' '-_' | tr -d '=')
            printf 'ss://%s@%s:%s#%s\n' "$encoded" "$displayhost" "$port" "$label";;
    esac
}
node_action() {
    local action=$1 name=${2:-} entry credential proto method port old newname
    node_select name "$name"
    entry=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.entry' "$STATE")
    case "$action" in
        rename)
            ask newname '新的节点名称' "$name"
            valid_name "$newname" || die '名称格式不合法。'
            [[ $newname != "$name" ]] || return 0
            jq -e --arg n "$newname" '.nodes[]|select(.id==$n)' "$STATE" >/dev/null && die '名称已存在。'
            begin_tx
            json_update --arg old "$name" --arg new "$newname" '(.nodes[]|select(.id==$old)|.id)=$new'
            name=$newname;;
        delete)
            confirm "删除节点 $name 的凭据（其他共享用户保留）" || return 0
            begin_tx; json_update --arg n "$name" '.nodes |= map(select(.id!=$n))';;
        enable|disable)
            begin_tx
            if [[ $action == enable ]]; then
                port=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.port' "$STATE")
                if ! jq -e --arg e "$entry" '.nodes[]|select(.entry==$e and .enabled)' "$STATE" >/dev/null; then check_port "$port"; fi
            fi
            json_update --arg n "$name" --argjson enabled "$([[ $action == enable ]] && echo true || echo false)" '(.nodes[]|select(.id==$n)|.enabled)=$enabled';;
        edit)
            proto=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.protocol' "$STATE")
            method=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.method' "$STATE")
            choose_credential credential "$proto" "$method"
            jq -e --arg c "$credential" --arg n "$name" '.nodes[]|select(.id!=$n and .credential==$c)' "$STATE" >/dev/null && die '凭据与其他节点重复。'
            begin_tx; json_update --arg n "$name" --arg c "$credential" '(.nodes[]|select(.id==$n)|.credential)=$c';;
        port)
            old=$(jq -r --arg n "$name" '.nodes[]|select(.id==$n)|.port' "$STATE")
            ask port '新的入口端口（同入口所有用户一起修改；WS仅修改内部端口）' "$old"
            valid_port "$port" || die '端口非法。'; port=$((10#$port))
            [[ $port != 80 && $port != 443 ]] || die '80/443保留给网站。'
            [[ $port != "$old" ]] || { ok '端口未变更。'; return 0; }
            jq -e --argjson p "$port" '.nodes[]|select(.port==$p)' "$STATE" >/dev/null && die '端口在状态中已保留。'
            begin_tx; check_port "$port"
            json_update --arg e "$entry" --argjson p "$port" '(.nodes[]|select(.entry==$e)|.port)=$p';;
        *) die '未知节点操作。';;
    esac
    apply_config; commit_tx
    ok "节点操作完成: $action $name"
    if [[ $action == edit || $action == port ]]; then node_export "$name"; fi
}

explain() {
    cat <<'EOF'
A：VLESS+REALITY+Vision直连（默认8443），网站单独使用80/443。
   代理不需要自有域名；网站仍需要域名和证书。
B：VLESS/VMess/Trojan + WebSocket，经Nginx TLS共用网站443。
   必须有解析正确的域名和有效证书；Xray只监听本机内部端口。
额外：上述三个协议可选独立TCP+TLS；Shadowsocks使用独立TCP+UDP端口。
VMess还可选独立WS（无外层TLS），仍使用VMess AEAD加密，但不伪装成HTTPS。
WS+TLS适合网站共用443；WS封装本身不会加速，直连REALITY通常开销更低。
只启动一个Xray进程。A/B是新建节点的默认模式，允许明确选择其他支持的组合。
TLS/REALITY降低内容暴露，但不保证匿名、无法识别或永久可用。
本工具不自动放行系统防火墙/云安全组，不创建账户，不修改SSH。
服务按当前提升权限后的root账户运行，网站默认仅静态文件。
EOF
}
install_component() {
    local c=$1
    case "$c" in xray|nginx|acme);; *) die '组件名必须为xray/nginx/acme。';; esac
    if [[ $(get ".components.$c") == true ]]; then ok "$c 已安装，更新请用 update。"; return 0; fi
    begin_tx
    if [[ $c == nginx ]]; then check_port 80; check_port 443; fi
    "install_$c"
    apply_config
    commit_tx
}
inspect_existing() {
    local service location
    for service in xray.service v2ray.service nginx.service x-ui.service; do
        location=$(systemctl show -p FragmentPath --value "$service" 2>/dev/null || true)
        if [[ -n $location ]]; then
            warn "发现非本工具服务: $service ($location)，保留；若端口冲突将单独处理。"
        fi
    done
    info "本工具残留检查完成；仅自动清理 $ROOT/tmp 中的暂存文件并恢复未完成事务。"
}
install_all() {
    local scheme website choice host own=false
    explain
    inspect_existing
    ask scheme '部署默认方案 A / B' "$(get .scheme)"
    scheme=${scheme^^}; [[ $scheme == A || $scheme == B ]] || die '方案只能是A或B。'
    json_update --arg s "$scheme" '.scheme=$s'
    if [[ -z $(get .host) ]]; then
        ask host 'VPS公网IP或直连域名（导出REALITY/SS链接使用，不自动猜测公网地址）' ''
        valid_host "$host" || die '连接地址无效。'
        json_update --arg h "$host" '.host=$h'
    fi
    warn '安装目录/服务使用root，不创建用户；请勿在此静态站点执行不可信程序。'
    info '建议至少保留500MB磁盘空闲；更新保留一个回滚快照。'
    local free_kb
    free_kb=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
    ((free_kb >= 512000)) || die '可用磁盘不足500MB，无法安全安装和回滚。'
    install_component xray
    ask website '是否同时安装网站和自动证书（yes/no；B必须yes）' yes
    if [[ $website == yes || $scheme == B ]]; then
        begin_tx
        if [[ $(get .components.nginx) != true ]]; then
            check_port 80; check_port 443; install_nginx
        fi
        [[ $(get .components.acme) == true ]] || install_acme
        apply_config; commit_tx
        if [[ $(jq '.sites|length' "$STATE") == 0 ]]; then site_add; fi
    fi
    ask choice '现在添加第一个/下一个代理节点？yes/no' yes
    [[ $choice != yes ]] || node_add
    ok '部署流程完成。以后运行 sudo vpskit；无需再次下载。'
}
update_component() {
    local c=$1
    if [[ $c == manager ]]; then update_manager; return; fi
    case "$c" in xray|nginx|acme);; *) die '更新目标：xray/nginx/acme/manager/all。';; esac
    ensure_component "$c"
    begin_tx
    if [[ $c == xray ]]; then
        local requested
        ask requested 'Xray版本：输入latest或具体v版本（默认经本脚本配置测试的版本）' "$XRAY_TESTED_VERSION"
        install_xray "$requested"
    else "install_$c"; fi
    apply_config
    if [[ $c == nginx ]]; then
        systemctl restart vpskit-nginx.service
        sleep 0.3
        systemctl is-active --quiet vpskit-nginx.service || die 'Nginx新程序启动失败。'
    fi
    commit_tx
}
update_all() {
    local c
    for c in xray nginx acme; do
        if [[ $(get ".components.$c") == true ]]; then update_component "$c"; fi
    done
    update_manager
    ok '全部已安装组件依次更新完成；未执行整机系统升级。'
}
update_manager() {
    local stage="$WORK/manager.new" v
    info "管理脚本更新来源: $SELF_URL"
    confirm '从你的GitHub仓库下载并替换管理脚本' || return 0
    fetch "$SELF_URL" "$stage"
    grep -Fq 'VPSKIT_SINGLE_FILE' "$stage" || die '文件标识不匹配。'
    bash -n "$stage"
    v=$(sed -n "s/^VERSION='\([0-9.]*\)'$/\1/p" "$stage" | head -1)
    [[ -n $v ]] || die '没有有效版本号。'
    cp "$ROOT/vpskit.sh" "$ROOT/backup/manager.previous"
    install -m 700 "$stage" "$ROOT/vpskit.sh.new"
    mv -f "$ROOT/vpskit.sh.new" "$ROOT/vpskit.sh"
    json_update --arg v "$v" '.manager=$v'
    ok "管理脚本已更新至$v；当前会话仍执行旧代码，下次唤醒使用新版本。"
}
rollback_last() {
    [[ -f $ROOT/backup/last/ready ]] || die '没有可回滚快照。'
    confirm '恢复最近一次操作前的节点、配置及程序；之后增加的节点将被撤销' || return 0
    restore_tx "$ROOT/backup/last" || die '回滚不完整，保留快照供排查。'
    rm -rf "$ROOT/backup/last"
    ok '回滚完成。'
}
remove_unit() {
    local u=$1
    if [[ -f $SYSTEMD/$u ]] && grep -Fq '# VPSKIT_OWNED' "$SYSTEMD/$u"; then
        systemctl disable --now "$u" 2>/dev/null || true
        rm -f -- "$SYSTEMD/$u"
        systemctl reset-failed "$u" 2>/dev/null || true
    fi
}
uninstall_component() {
    local c=$1
    case "$c" in xray|nginx|acme);; *) die '卸载目标：xray/nginx/acme/all。';; esac
    if [[ $c == nginx ]]; then
        jq -e '.nodes[]|select(.mode=="ws" or .mode=="tls")' "$STATE" >/dev/null && die '仍有域名/TLS节点，请先移除它们。'
        [[ $(jq '.sites|length' "$STATE") == 0 ]] || die '仍有网站绑定，请先执行 site remove。'
    fi
    if [[ $c == acme ]]; then
        [[ $(jq '.sites|length' "$STATE") == 0 ]] || die '仍有网站依赖自动证书，请先移除网站。'
    fi
    confirm "卸载$c及其私有资料；不会卸载系统原有同名程序" || return 0
    begin_tx
    case "$c" in
        xray) json_update '.nodes=[] | .components.xray=false | del(.versions.xray)'; systemctl disable --now vpskit-xray.service 2>/dev/null || true; rm -f "$XRAY" "$ROOT/config/xray.json";;
        nginx) json_update '.components.nginx=false | del(.versions.nginx)'; systemctl disable --now vpskit-nginx.service 2>/dev/null || true; rm -rf "$ROOT/nginx"; mkdir -p "$ROOT/nginx"; rm -f "$ROOT/config/nginx.conf";;
        acme) json_update '.components.acme=false | del(.versions.acme)'; rm -rf "$ROOT/acme" "$ROOT/certs"; mkdir -p "$ROOT/acme" "$ROOT/certs";;
    esac
    apply_config
    commit_tx
    # Component removal should not retain its binaries/secrets in a generic rollback copy.
    rm -rf "$ROOT/backup/last" "$ROOT/backup/manager.previous"
    case "$c" in xray) remove_unit vpskit-xray.service;; nginx) remove_unit vpskit-nginx.service;; esac
    systemctl daemon-reload
    ok "$c 已卸载；管理工具及其他组件保留。"
}
purge_owned_packages() {
    local -a pkgs=(); local p simulated removed
    [[ -s $ROOT/data/packages.added ]] || return 0
    while read -r p; do
        [[ $p =~ ^[a-z0-9][a-z0-9+.:_-]+$ ]] || die '依赖包清单异常。'
        if dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed; then pkgs+=("$p"); fi
    done < "$ROOT/data/packages.added"
    ((${#pkgs[@]})) || return 0
    printf '本工具新增过的依赖包：\n%s\n' "${pkgs[*]}"
    confirm '尝试移除这些共享依赖（若涉及其他包则拒绝）' || return 0
    simulated=$(apt-get -s purge "${pkgs[@]}") || die '卸载模拟失败，保留依赖。'
    while read -r removed; do
        [[ -z $removed ]] && continue
        printf '%s\n' "${pkgs[@]}" | grep -Fxq "$removed" || die "移除将影响其他软件包 $removed；已保留依赖。"
    done < <(printf '%s\n' "$simulated" | awk '$1=="Remv"||$1=="Purg"{print $2}')
    run apt-get -y purge "${pkgs[@]}"
}
uninstall_all() {
    printf '将删除：\n  %s\n  %s\n  VPSKit服务、续期timer、全部节点/私钥/网站/日志/备份\n' "$ROOT" "$ENTRY"
    printf '已配置网站：\n'; jq -r '.sites[].domain' "$STATE"
    warn '完整卸载不可恢复。请先把需要保留的网站文件复制到其他位置。不会删除其他工具的目录或系统共享日志。'
    confirm '完整卸载VPSKit' || return 0
    tuning_restore no
    UNINSTALLING=1
    local u
    for u in vpskit-maintain.timer vpskit-maintain.service vpskit-xray.service vpskit-nginx.service; do remove_unit "$u"; done
    systemctl daemon-reload
    # Optional dependency purge uses only a whitelist recorded at the actual dependency installation.
    purge_owned_packages
    [[ ! -L $ROOT && $(cat "$ROOT/.vpskit-owned") == VPSKIT_V1 && $(stat -c %u "$ROOT") == 0 ]] || die '目录归属检查失败，停止删除。'
    if [[ -L $ENTRY && $(readlink "$ENTRY") == "$ROOT/vpskit.sh" ]]; then rm -f "$ENTRY"; fi
    cd /
    LOGFILE=''; WORK=''
    rm -rf --one-file-system -- "$ROOT"
    [[ ! -e $ROOT ]] || die '仍有挂载点或不可删除内容，请人工检查 /opt/vpskit。'
    ok '完整卸载完成。本工具文件、入口、服务和任务已移除。'
}
status() {
    printf '\nVPSKit %s | 默认方案 %s | 目录 %s\n' "$VERSION" "$(get .scheme)" "$ROOT"
    free -m; df -h "$ROOT"
    jq -r '.versions|to_entries[]|"\(.key): \(.value)"' "$STATE"
    local u
    for u in xray nginx; do printf '%s: ' "$u"; systemctl is-active "vpskit-$u.service" || true; done
    printf '续期任务: '; systemctl is-active vpskit-maintain.timer || true
    printf '节点数: '; jq '.nodes|length' "$STATE"
    cert_status || true
}
doctor() {
    status
    validate_state
    [[ $(get .components.xray) != true ]] || "$XRAY" run -test -config "$ROOT/config/xray.json"
    [[ $(get .components.nginx) != true ]] || nginx_cmd -t -p "$ROOT/" -c "$ROOT/config/nginx.conf"
    printf '\n监听端口：\n'; ss -lntup
    printf '\n续期timer：\n'; systemctl list-timers vpskit-maintain.timer --no-pager
    local d
    while read -r d; do
        info "DNS解析 $d"; getent ahosts "$d" || warn '解析失败。'
        if [[ -s $ROOT/certs/$d/current/fullchain.pem ]]; then
            info "通过公网域名检查HTTPS $d（若使用CDN，检查的是CDN证书）"
            curl -fsSI --connect-timeout 10 --max-time 20 "https://$d/" || warn '公网HTTPS检查失败。'
            timeout 15 openssl s_client -connect "$d:443" -servername "$d" </dev/null 2>/dev/null | openssl x509 -noout -dates -issuer || warn '未读取到线上证书。'
        fi
    done < <(jq -r '.sites[].domain' "$STATE")
    warn '云安全组、实际客户端连通性、性能和REALITY目标适用性还需从客户端验收。'
}
logs() {
    local c=${1:-manager} file
    case "$c" in xray) file="$ROOT/logs/xray.log";; nginx) file="$ROOT/logs/nginx.log";; manager) file="$ROOT/logs/manage.log";; cert) journalctl -u vpskit-maintain.service -n 100 --no-pager; return;; *) die '日志目标：xray/nginx/manager/cert。';; esac
    [[ -f $file ]] || { warn '尚无日志。'; return 0; }
    tail -n 100 "$file"
}
service_action() {
    local action=$1 c=$2
    case "$action" in start|stop|restart);; *) die '服务操作必须是start/stop/restart。';; esac
    case "$c" in xray|nginx);; *) die '服务目标必须是xray/nginx。';; esac
    ensure_component "$c"
    systemctl "$action" "vpskit-$c.service"
    systemctl is-active "vpskit-$c.service" || [[ $action == stop ]]
}
maintenance() {
    rotate_logs
    if [[ $(get .components.acme) == true ]]; then cert_renew; fi
}
# Reversible system-wide tuning. Kept outside generic configuration snapshots so
# ordinary node/certificate rollback cannot silently change kernel tuning files.
tuning_paths_ok() {
    [[ -d ${SYSCTL_LINK%/*} && ! -L ${SYSCTL_LINK%/*} ]] || die 'sysctl.d目录异常。'
    if [[ -e $SYSCTL_LINK || -L $SYSCTL_LINK ]]; then
        [[ -L $SYSCTL_LINK && $(readlink "$SYSCTL_LINK") == "$ROOT/data/sysctl.conf" ]] || die "$SYSCTL_LINK 已被其他工具使用，保留并停止。"
    fi
}
tuning_write_persistent() {
    tuning_paths_ok
    if [[ -f $ROOT/data/tuning.json ]] && jq -e '.keys|length>0' "$ROOT/data/tuning.json" >/dev/null; then
        { printf '# VPSKIT_OWNED -- manage with vpskit optimize\n'; jq -r '.keys|to_entries[]|"\(.key) = \(.value.applied)"' "$ROOT/data/tuning.json"; } > "$ROOT/data/sysctl.conf.new"
        chmod 600 "$ROOT/data/sysctl.conf.new"
        mv -f "$ROOT/data/sysctl.conf.new" "$ROOT/data/sysctl.conf"
        ln -sfn "$ROOT/data/sysctl.conf" "$SYSCTL_LINK"
    else
        if [[ -L $SYSCTL_LINK ]]; then rm -f "$SYSCTL_LINK"; fi
        rm -f "$ROOT/data/sysctl.conf" "$ROOT/data/tuning.json"
    fi
}
tuning_begin() {
    local intent=$1 tx="$ROOT/backup/tuning-transaction" f
    tuning_paths_ok
    [[ ! -e $tx ]] || die '有待恢复的网络调优事务，请执行 repair。'
    mkdir -p "$tx"
    for f in tuning.json sysctl.conf; do [[ ! -f $ROOT/data/$f ]] || cp -a "$ROOT/data/$f" "$tx/$f"; done
    [[ ! -L $SYSCTL_LINK ]] || touch "$tx/had-link"
    cp "$intent" "$tx/changes.json"
    touch "$tx/ready"
}
tuning_recover() {
    local tx="$ROOT/backup/tuning-transaction" row key before after current f
    [[ -d $tx ]] || return 0
    if [[ ! -f $tx/ready ]]; then rm -rf "$tx"; return 0; fi
    tuning_paths_ok
    warn '恢复上次未完成的网络调优。'
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.before <<< "$row"); after=$(jq -r .value.after <<< "$row")
        case "$key" in net.ipv4.tcp_congestion_control|net.core.default_qdisc|net.ipv4.tcp_mtu_probing);; *) warn '调优快照中有未知参数。'; return 1;; esac
        current=$(sysctl -n "$key") || return 1
        if [[ $current == "$before" ]]; then continue; fi
        if [[ $current != "$after" ]]; then warn "$key 已被外部改为 $current；保留快照，需核对后再恢复。"; return 1; fi
        sysctl -q -w "$key=$before" || return 1
    done < <(jq -c 'to_entries[]' "$tx/changes.json")
    for f in tuning.json sysctl.conf; do
        if [[ -f $tx/$f ]]; then cp -a "$tx/$f" "$ROOT/data/$f" || return 1; else rm -f "$ROOT/data/$f"; fi
    done
    if [[ -f $tx/had-link ]]; then ln -sfn "$ROOT/data/sysctl.conf" "$SYSCTL_LINK"; else rm -f "$SYSCTL_LINK"; fi
    rm -rf "$tx"
    ok '网络调优已恢复到该次操作之前。'
}
tuning_apply() {
    local kind=$1 key value current previous tracked intent="$WORK/tuning-intent.json" record="$WORK/tuning-record.json" i
    local -a keys=() values=()
    case "$kind" in
        bbr)
            confirm '启用BBR与默认fq队列；这会影响整台VPS的新TCP连接' || return 0
            if ! sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fxq bbr; then
                if command -v modprobe >/dev/null; then modprobe tcp_bbr || true; fi
            fi
            sysctl -n net.ipv4.tcp_available_congestion_control | tr ' ' '\n' | grep -Fxq bbr || die '当前内核不提供BBR；保留原值，不安装内核、不重启。'
            if command -v modprobe >/dev/null; then modprobe sch_fq 2>/dev/null || true; fi
            keys=(net.core.default_qdisc net.ipv4.tcp_congestion_control); values=(fq bbr);;
        mtu)
            confirm '启用按需TCP MTU黑洞探测（值1）；适用于部分卡顿链路，影响整台VPS' || return 0
            keys=(net.ipv4.tcp_mtu_probing); values=(1);;
        *) die '未知调优方式。';;
    esac
    tuning_paths_ok
    printf '{}\n' > "$intent"
    if [[ -f $ROOT/data/tuning.json ]]; then cp "$ROOT/data/tuning.json" "$record"; else printf '{"keys":{}}\n' > "$record"; fi
    for i in "${!keys[@]}"; do
        key=${keys[$i]}; value=${values[$i]}
        current=$(sysctl -n "$key") || die "内核未提供 $key，未应用调优。"
        tracked=$(jq -r --arg k "$key" '.keys[$k].applied // empty' "$record")
        [[ -z $tracked || $current == "$tracked" ]] || die "$key 已被其他工具修改；先运行 optimize restore，再重新选择。"
        previous=$(jq -r --arg k "$key" --arg v "$current" '.keys[$k].before // $v' "$record")
        jq --arg k "$key" --arg v "$previous" --arg a "$value" '.keys[$k]={before:$v,applied:$a}' "$record" > "$record.new"; mv "$record.new" "$record"
        jq --arg k "$key" --arg b "$current" --arg a "$value" '.[$k]={before:$b,after:$a}' "$intent" > "$intent.new"; mv "$intent.new" "$intent"
    done
    tuning_begin "$intent"
    for i in "${!keys[@]}"; do
        key=${keys[$i]}; value=${values[$i]}
        info "设置 $key=$value"
        sysctl -q -w "$key=$value"
        [[ $(sysctl -n "$key") == "$value" ]] || die "$key 未生效。"
    done
    mv "$record" "$ROOT/data/tuning.json"
    tuning_write_persistent
    rm -rf "$ROOT/backup/tuning-transaction"
    ok '调优已应用并持久化，可用 optimize restore 恢复。'
    warn '现有监听器/连接可能仍使用原算法；维护时重启本工具服务后再对比。fq默认值不会替换现有网卡队列。'
    tuning_status
}
tuning_restore() {
    local interactive=${1:-yes} row key before applied current intent="$WORK/tuning-intent.json"
    if [[ ! -f $ROOT/data/tuning.json ]]; then
        [[ ! -L $SYSCTL_LINK || $(readlink "$SYSCTL_LINK") != "$ROOT/data/sysctl.conf" ]] || die '调优记录缺失但仍有持久化链接，请先人工核对，防止丢失原值。'
        ok '没有本工具管理的内核调优。'; return 0
    fi
    [[ $interactive != yes ]] || { confirm '恢复本工具修改前的内核参数，并移除调优持久化配置' || return 0; }
    printf '{}\n' > "$intent"
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.before <<< "$row"); applied=$(jq -r .value.applied <<< "$row")
        case "$key" in net.ipv4.tcp_congestion_control|net.core.default_qdisc|net.ipv4.tcp_mtu_probing);; *) die '调优记录参数异常。';; esac
        current=$(sysctl -n "$key") || die "无法读取 $key；保留恢复资料。"
        if [[ $current != "$applied" ]]; then warn "$key 已被外部改为 $current，保留外部值。"; continue; fi
        jq --arg k "$key" --arg b "$current" --arg a "$before" '.[$k]={before:$b,after:$a}' "$intent" > "$intent.new"; mv "$intent.new" "$intent"
    done < <(jq -c '.keys|to_entries[]' "$ROOT/data/tuning.json")
    tuning_begin "$intent"
    while read -r row; do
        key=$(jq -r .key <<< "$row"); before=$(jq -r .value.after <<< "$row")
        sysctl -q -w "$key=$before"
        [[ $(sysctl -n "$key") == "$before" ]] || die "恢复 $key 未生效，保留资料。"
    done < <(jq -c 'to_entries[]' "$intent")
    printf '{"keys":{}}\n' > "$ROOT/data/tuning.json"
    tuning_write_persistent
    rm -rf "$ROOT/backup/tuning-transaction"
    ok '内核调优已恢复；现有连接/网卡队列的状态由内核继续管理。'
}
tuning_status() {
    local key
    printf '\n%s网络调优状态%s\n' "$BLUE" "$RESET"
    for key in net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing; do
        printf '  %s = %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || printf '内核未提供')"
    done
    printf '  静态网站gzip: %s\n' "$(get '.performance.gzip // false')"
    if [[ -f $ROOT/data/tuning.json ]]; then jq -r '.keys|to_entries[]|"  已记录：\(.key)，原值=\(.value.before)，设定值=\(.value.applied)"' "$ROOT/data/tuning.json"; fi
    if command -v tc >/dev/null; then printf '\n当前网卡队列（只读）：\n'; tc qdisc show || true; fi
    printf '\nBBR取决于内核与链路；WS本身不加速。gzip只减少静态文本传输量。\n不扩大TCP缓冲、不更换内核、不自动修改网卡队列或防火墙。\n'
}
gzip_action() {
    local enabled=$1
    ensure_component nginx
    begin_tx
    json_update --argjson e "$enabled" '.performance.gzip=$e'
    apply_config; commit_tx
    ok "静态网站轻量gzip=$enabled；级别2，只压缩大于1KB的文本，不压缩代理节点或动态网站响应。"
}
optimize_action() {
    case "${1:-status}" in
        status) tuning_status;; bbr|mtu) tuning_apply "$1";; restore) tuning_restore;;
        gzip-on) gzip_action true;; gzip-off) gzip_action false;;
        *) die '用法: vpskit optimize status|bbr|mtu|restore|gzip-on|gzip-off';;
    esac
}

help_text() {
    cat <<'EOF'
VPSKit 单文件管理器
  sudo bash vpskit.sh                  首次启动/菜单
  sudo vpskit                         管理菜单
  sudo vpskit install [xray|nginx|acme] 完整向导/单组件安装
  sudo vpskit node add                 添加节点/共享入口用户
  sudo vpskit node list
  sudo vpskit node export [名称]       输出含凭据的客户端链接
  sudo vpskit node edit [名称]         更换UUID/密码
  sudo vpskit node rename [名称]       修改节点名称
  sudo vpskit node port [名称]         修改整个入口端口
  sudo vpskit node enable|disable|delete [名称]
  sudo vpskit site add|edit|list|remove
  sudo vpskit cert issue|renew|status
  sudo vpskit update xray|nginx|acme|manager|all
  sudo vpskit optimize                 网络与网站优化菜单
  sudo vpskit optimize status|bbr|mtu|restore|gzip-on|gzip-off
  sudo vpskit rollback                 回滚最近一次配置事务（内核调优单独恢复）
  sudo vpskit service start|stop|restart xray|nginx
  sudo vpskit status|doctor|repair
  sudo vpskit logs xray|nginx|manager|cert
  sudo vpskit uninstall xray|nginx|acme|all
  bash vpskit.sh help|version|explain   不需要root，不修改系统
  bash vpskit.sh selftest              本地静态功能测试，不联网、不部署
选项: --no-color（放在命令之前）
修改命令需要交互输入；定时续期为无人值守。无危险的全局--force。
默认仓库文件: biao169/hijkpw-scripts-mod/main/vpskit.sh
仅支持Debian 12+ / Ubuntu 18.04+、systemd、amd64/arm64。不创建用户、不修改SSH。
Ubuntu旧版本需要仍可用的软件源及更新后的基础库；脚本不改软件源。
仅一个Xray进程，Nginx单worker；面板无常驻Web进程，适合小型静态网站与少量连接。
网站内容: /opt/vpskit/www/域名。证书续期依赖DNS和网络可用性。
默认拒绝代理访问回环/私网/云元数据地址，不下载GeoIP/GeoSite大规则。
默认内核锁定到本地验证版本；更新时可输入latest或指定版本。
配置变更会重启Xray；大量持续连接时请安排维护窗口。
完整卸载后系统软件包日志/已存在依赖不属于本工具文件，不擦除。
EOF
}
panel_title() { printf '\n%s━━ %s ━━%s\n' "$BLUE" "$1" "$RESET"; }
menu_item() { printf '  %s%2s%s  %s\n      %s%s%s\n' "$GREEN" "$1" "$RESET" "$2" "$BLUE" "$3" "$RESET"; }
panel_header() {
    local xstate nstate memory disk count
    xstate=$(systemctl is-active vpskit-xray.service 2>/dev/null || true)
    nstate=$(systemctl is-active vpskit-nginx.service 2>/dev/null || true)
    memory=$(free -m | awk '/^Mem:/{printf "%s/%s MiB（可用%s）",$3,$2,$7}')
    disk=$(df -h "$ROOT" | awk 'NR==2{printf "%s可用",$4}')
    count=$(jq '[.nodes[]|select(.enabled)]|length' "$STATE")
    panel_title "VPSKit $VERSION · 轻量终端面板"
    printf '  方案%s | 内存 %s | 磁盘 %s\n' "$(get .scheme)" "$memory" "$disk"
    printf '  Xray: %s | Nginx: %s | 启用节点: %s\n' "${xstate:-未安装}" "${nstate:-未安装}" "$count"
    printf '  数据: %s | 唤醒: sudo vpskit\n' "$ROOT"
}
menu_run() {
    # A subshell retains errexit and its rollback trap. Calling it in if/|| would
    # disable errexit in Bash functions, allowing failed commands to be committed.
    local rc
    set +e
    trap - ERR
    (
        set -Ee
        trap 'on_error $? $LINENO' ERR
        trap on_exit EXIT
        [[ -f $STATE ]] || die '部署已被另一会话移除，请退出面板。'
        flock -w 5 "$LOCK_FD" || die '另一个管理任务正在执行，请稍后再试。'
        [[ $(stat -Lc '%d:%i' "/proc/self/fd/$LOCK_FD") == "$(stat -Lc '%d:%i' "$ROOT/run/manage.lock")" ]] || die '部署锁已被另一会话替换，请退出并重新运行vpskit。'
        HAVE_LOCK=1
        PANEL_IDLE=0
        WORK=$(mktemp -d "$ROOT/tmp/menu.XXXXXXXX")
        TX=0
        recover
        "$@"
    )
    rc=$?
    set -e
    trap 'on_error $? $LINENO' ERR
    flock -u "$LOCK_FD"
    if ((rc != 0)); then warn "本次操作未完成（$rc），已返回面板。"; fi
    if [[ -f $STATE ]]; then local answer; ask answer '按回车返回菜单' ''; fi
}
component_menu() {
    local action=$1 choice
    while [[ -f $STATE ]]; do
        panel_title "$action · 独立组件管理"
        case "$action" in
            install) menu_item 1 '完整安装 / A、B方案选择' '先显示要求，再安装所选组件并添加节点';;
            update) menu_item 1 '更新所有已装组件' '依次更新Xray、Nginx、证书工具、管理脚本';;
            uninstall) menu_item 1 '完整卸载' '删除本工具全部资料，并恢复本工具内核调优';;
        esac
        menu_item 2 'Xray代理核心' '只处理代理程序；卸载会删除所有代理节点'
        menu_item 3 'Nginx网站与WS入口' '只处理独立Nginx；有依赖的网站/节点时禁止卸载'
        menu_item 4 'acme.sh自动证书' '只处理证书工具；有证书依赖时禁止卸载'
        [[ $action != update ]] || menu_item 5 '管理脚本' '从你配置的GitHub地址更新；下次唤醒生效'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            0) return;;
            1) menu_run "${action}_all";;
            2) menu_run "${action}_component" xray;;
            3) menu_run "${action}_component" nginx;;
            4) menu_run "${action}_component" acme;;
            5) if [[ $action == update ]]; then menu_run update_manager; else warn '无效选择。'; fi;;
            *) warn '无效选择。';;
        esac
    done
}
node_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '节点与用户管理'
        menu_item 1 '添加节点 / 共享入口用户' '选择协议和传输；UUID、密码、端口可默认或自定义'
        menu_item 2 '节点列表' '查看协议、传输、入口端口和启用状态'
        menu_item 3 '导出客户端链接' '链接含凭据；请仅交给可信客户端'
        menu_item 4 '更换UUID / 密码' '旧凭据立即失效，同入口其他用户保留'
        menu_item 5 '修改入口端口' '检查占用；共享该入口的所有用户一起修改'
        menu_item 6 '修改节点名称' '修改管理名称与导出链接备注'
        menu_item 7 '启用节点' '检查入口端口，再恢复代理服务'
        menu_item 8 '停用节点' '保留参数，可随时再次启用'
        menu_item 9 '删除节点' '删除该用户凭据；操作前确认'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run node_add;; 2) menu_run node_list;; 3) menu_run node_export;;
            4) menu_run node_action edit;; 5) menu_run node_action port;; 6) menu_run node_action rename;;
            7) menu_run node_action enable;; 8) menu_run node_action disable;; 9) menu_run node_action delete;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
site_list() { jq '.sites|map(del(.email))' "$STATE"; }
site_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '网站与证书'
        menu_item 1 '添加网站' '绑定域名，选择静态目录或本机应用反向代理'
        menu_item 2 '修改网站' '修改站点内容入口等参数'
        menu_item 3 '网站列表' '查看域名和部署状态'
        menu_item 4 '删除网站' '先检查节点依赖，再确认删除'
        menu_item 5 '签发 / 重新签发证书' 'HTTP验证或支持的DNS API验证'
        menu_item 6 '检查续期' '调用ACME按到期策略续期，不强制重复签发'
        menu_item 7 '证书状态' '查看当前证书与到期时间'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run site_add;; 2) menu_run site_edit;; 3) menu_run site_list;; 4) menu_run site_remove;;
            5) menu_run cert_issue;; 6) menu_run cert_renew;; 7) menu_run cert_status;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
optimize_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '网络与网站优化（512MB保守设置）'
        menu_item 1 '查看能力与当前状态' '检查内核算法、MTU探测、网卡队列和gzip'
        menu_item 2 '启用BBR + 默认fq' '可能改善部分高延迟/丢包链路；需要内核支持'
        menu_item 3 '启用按需MTU探测' '检测到MTU黑洞时尝试较小报文；不保证提速'
        menu_item 4 '恢复内核原值' '撤销本工具的BBR/fq/MTU设置和持久化文件'
        menu_item 5 '开启静态网站轻量gzip' '压缩HTML/CSS/JS等；级别2，减少文本传输量'
        menu_item 6 '关闭静态网站gzip' '节省压缩CPU；适合CPU受限或已预压缩的站点'
        menu_item 0 '返回' 'WS已关闭代理缓冲；TLS会话缓存、TCP_NODELAY默认启用'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run tuning_status;; 2) menu_run tuning_apply bbr;; 3) menu_run tuning_apply mtu;;
            4) menu_run tuning_restore;; 5) menu_run gzip_action true;; 6) menu_run gzip_action false;;
            0) return;; *) warn '无效选择。';;
        esac
    done
}
service_menu() {
    local choice action component
    panel_title '服务控制'
    menu_item 1 '启动' '启动已经安装的组件'
    menu_item 2 '停止' '停止组件；网站或代理会暂时不可用'
    menu_item 3 '重启' '重新建立监听器；现有连接可能中断'
    menu_item 0 '返回' '不修改服务'
    ask choice '操作编号' 0
    case "$choice" in 0) return;; 1) action=start;; 2) action=stop;; 3) action=restart;; *) warn '无效选择。'; return;; esac
    menu_item 1 'Xray' '代理节点服务'
    menu_item 2 'Nginx' '网站和WS+TLS入口'
    ask choice '组件编号' 1
    case "$choice" in 1) component=xray;; 2) component=nginx;; *) warn '无效选择。'; return;; esac
    menu_run service_action "$action" "$component"
}
operations_menu() {
    local choice
    while [[ -f $STATE ]]; do
        panel_title '状态、日志与维护'
        menu_item 1 '运行状态' '查看资源、组件版本、节点和证书状态'
        menu_item 2 '诊断检查' '验证配置，查看端口、DNS、HTTPS和续期timer'
        menu_item 3 'Xray日志' '最近100行代理错误日志'
        menu_item 4 'Nginx日志' '最近100行网站/WS入口错误日志'
        menu_item 5 '管理日志' '最近100行安装与管理过程日志'
        menu_item 6 '证书任务日志' '查看systemd续期任务结果'
        menu_item 7 '恢复中断事务' '重试恢复上次未完成的配置或调优操作'
        menu_item 8 '回滚最近一次配置' '恢复节点、证书和程序快照；内核调优在优化菜单恢复'
        menu_item 9 '服务启动 / 停止 / 重启' '按组件控制，操作可能中断现有连接'
        menu_item 0 '返回' '回到主菜单'
        ask choice '选择编号' 0
        case "$choice" in
            1) menu_run status;; 2) menu_run doctor;; 3) menu_run logs xray;; 4) menu_run logs nginx;;
            5) menu_run logs manager;; 6) menu_run logs cert;; 7) menu_run recover;; 8) menu_run rollback_last;;
            9) service_menu;; 0) return;; *) warn '无效选择。';;
        esac
    done
}
main_menu() {
    local choice
    # An idle panel must not block hourly certificate renewal or another terminal.
    PANEL_IDLE=1
    HAVE_LOCK=0
    flock -u "$LOCK_FD"
    while [[ -f $STATE ]]; do
        panel_header
        menu_item 1 '部署与安装' 'A: REALITY直连；B: WS+TLS与网站共用443'
        menu_item 2 '节点与用户' '添加、导出、修改、停用或删除多个代理节点'
        menu_item 3 '网站与证书' '静态/反代网站、域名证书签发与自动续期'
        menu_item 4 '网络与网站优化' 'BBR、MTU探测、gzip；可检测、启用和恢复'
        menu_item 5 '组件更新' '独立更新或全部更新，失败时恢复配置'
        menu_item 6 '状态、日志与维护' '资源用量、诊断、服务控制与事务回滚'
        menu_item 7 '卸载' '按组件卸载，或删除本工具全部资料'
        menu_item 8 '方案说明与命令帮助' '查看要求、传输区别和命令行入口'
        menu_item 0 '退出' '后台代理、网站和自动续期继续运行'
        ask choice '请选择数字' 0
        case "$choice" in
            1) component_menu install;; 2) node_menu;; 3) site_menu;; 4) optimize_menu;;
            5) component_menu update;; 6) operations_menu;; 7) component_menu uninstall;;
            8) menu_run show_help;; 0) return;; *) warn '无效选择，请输入菜单编号。';;
        esac
    done
}
show_help() { explain; help_text; }

selftest() {
    command -v jq >/dev/null || die 'selftest需要jq。'
    local t test_fail=0
    for t in example.com xn--fiqs8s.example a-b.example; do valid_domain "$t" || test_fail=1; done
    for t in 'a;reboot.com' '../x.com' '-a.example' 'a..example' 'a.com/new' '*.example.com'; do if valid_domain "$t"; then test_fail=1; fi; done
    for t in 1 443 65535 08443; do valid_port "$t" || test_fail=1; done
    for t in 0 65536 abc '80;id' -1; do if valid_port "$t"; then test_fail=1; fi; done
    valid_uuid '12345678-1234-1234-1234-123456789abc' || test_fail=1
    if valid_uuid '$(id)'; then test_fail=1; fi
    valid_ws_path /abcdefgh || test_fail=1
    if valid_ws_path '/x; }'; then test_fail=1; fi
    valid_upstream 'http://127.0.0.1:8000' || test_fail=1
    if valid_upstream 'http://example.com:80'; then test_fail=1; fi
    ((test_fail == 0)) || die '输入验证自测失败。'
    bash -n "${BASH_SOURCE[0]}"
    ok '输入验证、注入字符拒绝和Bash语法自测通过（不代替实际VPS部署验收）。'
}
main() {
    if [[ ${1:-} == _service ]]; then
        (($# == 2)) || die '内部服务参数错误。'
        service_runner "$2"; return
    fi
    if [[ ${1:-} == --no-color ]]; then NO_COLOR_FLAG=1; shift; fi
    colors
    validate_cli "$@"
    case "${1:-}" in help|--help|-h) help_text; return;; version|--version) echo "$VERSION"; return;; explain) explain; return;; selftest) selftest; return;; esac
    check_root; detect_system
    if { exec {TTY_FD}<> /dev/tty; } 2>/dev/null; then :; else TTY_FD=''; fi
    trap 'on_error $? $LINENO' ERR
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    safe_root
    # Read-only commands on an empty system must not pretend that a deployment exists.
    if [[ ! -e $STATE && ${1:-install} != install && $# -gt 0 ]]; then die '尚未安装，请运行 bash vpskit.sh install。'; fi
    install_deps
    init_state
    recover
    if [[ ! -f $ROOT/vpskit.sh ]]; then persist_self
    elif [[ ${BASH_SOURCE[0]} != "$ROOT/vpskit.sh" && ${BASH_SOURCE[0]} != "$ENTRY" ]] && ! grep -Fxq "VERSION='$VERSION'" "$ROOT/vpskit.sh"; then
        # A locally downloaded/new process-substitution invocation upgrades the
        # installed service runner too. The caller explicitly executed this file.
        cp "$ROOT/vpskit.sh" "$ROOT/backup/manager.previous"
        persist_self
        json_update --arg v "$VERSION" '.manager=$v'
    fi
    case "${1:-menu}" in
        menu) main_menu;;
        install) if [[ -n ${2:-} ]]; then install_component "$2"; else install_all; fi;;
        node)
            case "${2:-list}" in
                add) node_add;; list) node_list;; export) node_export "${3:-}";;
                edit|rename|port|enable|disable|delete) node_action "$2" "${3:-}";;
                *) die '未知节点子命令。';;
            esac;;
        site) case "${2:-list}" in add) site_add;; edit) site_edit;; list) jq '.sites|map(del(.email))' "$STATE";; remove) site_remove;; *) die '未知网站子命令。';; esac;;
        cert) case "${2:-status}" in issue) cert_issue;; renew) cert_renew;; status) cert_status;; *) die '未知证书子命令。';; esac;;
        update) if [[ ${2:-} == all ]]; then update_all; else update_component "${2:-xray}"; fi;;
        uninstall) if [[ ${2:-} == all ]]; then uninstall_all; else uninstall_component "${2:-xray}"; fi;;
        service) service_action "${2:-}" "${3:-}";;
        status) status;; logs) logs "${2:-manager}";; doctor) doctor;; repair) recover; doctor;; rollback) rollback_last;;
        optimize) if [[ -z ${2:-} ]]; then PANEL_IDLE=1; HAVE_LOCK=0; flock -u "$LOCK_FD"; optimize_menu; else optimize_action "$2"; fi;;
        maintenance) maintenance;;
        *) help_text; die '未知命令。';;
    esac
}
# All function definitions are parsed before main. Source-only use is reserved for local tests.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
