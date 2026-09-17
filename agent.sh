#!/bin/sh

# Nezha Agent v2.3.5 repacked installer.
# Supports Linux, FreeBSD and macOS binaries published by nezha-rs/agent.

NZ_BASE_PATH="${NZ_BASE_PATH:-/opt/nezha}"
NZ_AGENT_PATH="${NZ_AGENT_PATH:-${NZ_BASE_PATH}/agent}"
NZ_RELEASE_TAG='v2.3.5-repacked'
NZ_RELEASE_REPOSITORY='nezha-rs/agent'
NZ_RELEASE_BASE="https://github.com/${NZ_RELEASE_REPOSITORY}/releases/download/${NZ_RELEASE_TAG}"
NZ_DOWNLOAD_TIMEOUT="${NZ_DOWNLOAD_TIMEOUT:-180}"
CPUINFO_PATH="${NZ_CPUINFO_PATH:-/proc/cpuinfo}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

LOG_FILE="${TMPDIR:-/tmp}/nezha-agent-install.$$.log"
TEMP_BINARY="${TMPDIR:-/tmp}/nezha-agent.download.$$"
NOTIFICATION_SENT=0
DOWNLOAD_TOOL=""

cleanup() {
    rm -f "$TEMP_BINARY"
    [ "$LOG_FILE" = /dev/null ] || rm -f "$LOG_FILE"
}

append_log() {
    printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
    append_log "INFO: $*"
}

success() {
    printf "${green}%s${plain}\n" "$*"
    append_log "SUCCESS: $*"
}

err() {
    printf "${red}%s${plain}\n" "$*" >&2
    append_log "ERROR: $*"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        "$@"
    elif has_cmd sudo; then
        sudo "$@"
    else
        err "Root privileges are required and sudo is not installed."
        return 1
    fi
}

download_to() {
    url="$1"
    destination="$2"
    client_found=0

    if has_cmd curl; then
        client_found=1
        DOWNLOAD_TOOL="curl"
        rm -f "$destination"
        curl -fL --connect-timeout 20 --max-time "$NZ_DOWNLOAD_TIMEOUT" \
            --retry 3 --retry-delay 2 -o "$destination" "$url" >> "$LOG_FILE" 2>&1 && return 0
        append_log "WARN: curl download failed; trying another available client"
    fi
    if has_cmd wget; then
        client_found=1
        DOWNLOAD_TOOL="wget"
        rm -f "$destination"
        wget -O "$destination" "$url" >> "$LOG_FILE" 2>&1 && return 0
        append_log "WARN: wget download failed; trying another available client"
    fi
    if has_cmd uclient-fetch; then
        client_found=1
        DOWNLOAD_TOOL="uclient-fetch"
        rm -f "$destination"
        uclient-fetch -O "$destination" "$url" >> "$LOG_FILE" 2>&1 && return 0
        append_log "WARN: uclient-fetch download failed; trying BusyBox wget"
    fi
    if has_cmd busybox && busybox wget --help >/dev/null 2>&1; then
        client_found=1
        DOWNLOAD_TOOL="busybox wget"
        rm -f "$destination"
        busybox wget -O "$destination" "$url" >> "$LOG_FILE" 2>&1 && return 0
    fi
    if [ "$client_found" = 0 ]; then
        err "A download tool is required: curl, wget, uclient-fetch, or BusyBox wget."
    fi
    return 1
}

url_encode() {
    has_cmd od || return 1
    printf '%s' "$1" | od -An -tx1 -v | tr ' ' '\n' | while read -r hex; do
        [ -n "$hex" ] && printf '%%%s' "$hex"
    done
}

send_telegram_message() {
    message="$1"

    [ -n "${TG_BOT_TOKEN:-}" ] || return 0
    [ -n "${TG_CHAT_ID:-}" ] || return 0
    api_url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

    if has_cmd curl; then
        if curl -fsS --connect-timeout 20 --max-time 45 --retry 2 \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "disable_web_page_preview=true" \
            "$api_url" >/dev/null 2>&1; then
            return 0
        fi
    fi
    if has_cmd wget && has_cmd od; then
        post_data="chat_id=$(url_encode "$TG_CHAT_ID")&text=$(url_encode "$message")&disable_web_page_preview=true"
        if wget -qO- --post-data="$post_data" "$api_url" >/dev/null 2>&1; then
            return 0
        fi
    fi
    if has_cmd uclient-fetch && has_cmd od; then
        post_data="chat_id=$(url_encode "$TG_CHAT_ID")&text=$(url_encode "$message")&disable_web_page_preview=true"
        if uclient-fetch -qO- --post-data="$post_data" "$api_url" >/dev/null 2>&1; then
            return 0
        fi
    fi
    if has_cmd busybox && has_cmd od && busybox wget --help 2>&1 | grep -q -- '--post-data'; then
        post_data="chat_id=$(url_encode "$TG_CHAT_ID")&text=$(url_encode "$message")&disable_web_page_preview=true"
        if busybox wget -qO- --post-data="$post_data" "$api_url" >/dev/null 2>&1; then
            return 0
        fi
    fi
    append_log "WARN: Telegram notification failed or no compatible HTTP POST client was found"
    return 0
}

sanitize_log() {
    if [ ! -r "$LOG_FILE" ]; then
        return 0
    fi
    awk -v secret="${NZ_CLIENT_SECRET:-}" -v uuid="${NZ_UUID:-}" '
        {
            line = $0
            if (length(secret) > 0) {
                while ((position = index(line, secret)) > 0) {
                    line = substr(line, 1, position - 1) "***" substr(line, position + length(secret))
                }
            }
            if (length(uuid) > 0) {
                while ((position = index(line, uuid)) > 0) {
                    line = substr(line, 1, position - 1) "***" substr(line, position + length(uuid))
                }
            }
            print line
        }
    ' "$LOG_FILE" | sed \
        -e 's/\(NZ_CLIENT_SECRET[=:][[:space:]]*\)[^[:space:]]*/\1***/g' \
        -e 's/\([Cc]lient[_ -]*[Ss]ecret[=:][[:space:]]*\)[^[:space:]]*/\1***/g' \
        -e 's/\(NZ_UUID[=:][[:space:]]*\)[^[:space:]]*/\1***/g' \
        -e 's/\(TG_BOT_TOKEN[=:][[:space:]]*\)[^[:space:]]*/\1***/g' | \
        tail -n 20 | cut -c 1-140
}

notify_result() {
    status="$1"
    [ "$NOTIFICATION_SENT" = "0" ] || return 0
    NOTIFICATION_SENT=1
    [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0

    host_name="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)"
    kernel="$(uname -sr 2>/dev/null || printf unknown)"
    details="$(sanitize_log)"
    message="Nezha Agent installation: ${status}
Host: ${host_name}
Kernel: ${kernel}
System: ${OS_DETAILS:-unknown}
uname -m: ${MACHINE:-unknown}
Package ABI: ${PACKAGE_ABI:-none}
Platform: ${DETECTED_OS:-unknown}
Architecture: ${DETECTED_ARCH:-unknown}
CPU details: ${CPU_DETAILS:-unknown}
Asset: ${ASSET_NAME:-not-selected}
Downloader: ${DOWNLOAD_TOOL:-not-used}
Server: ${NZ_SERVER:-not-set}
TLS: ${NZ_TLS:-false}

Install log:
${details}"
    send_telegram_message "$message"
}

die() {
    err "$*"
    notify_result failed
    cleanup
    exit 1
}

detect_package_abi() {
    PACKAGE_ABI=""
    if has_cmd opkg; then
        PACKAGE_ABI="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 != "all" && $2 != "noarch" { value=$2 } END { print value }')"
    elif has_cmd apk; then
        PACKAGE_ABI="$(apk --print-arch 2>/dev/null || true)"
    elif has_cmd dpkg; then
        PACKAGE_ABI="$(dpkg --print-architecture 2>/dev/null || true)"
    elif has_cmd rpm; then
        PACKAGE_ABI="$(rpm --eval '%{_arch}' 2>/dev/null || true)"
    fi
}

elf_data_byte() {
    for elf_file in /bin/busybox /bin/sh /usr/bin/env; do
        if [ -r "$elf_file" ] && has_cmd dd && has_cmd od; then
            byte="$(dd if="$elf_file" bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d '[:space:]')"
            case "$byte" in
                1|2) printf '%s\n' "$byte"; return 0 ;;
            esac
        fi
    done
    return 1
}

detect_mips_endian() {
    case "$PACKAGE_ABI" in
        mipsel*|mipsle*) printf '%s\n' little; return 0 ;;
        mips64el*|mips64le*) printf '%s\n' little; return 0 ;;
        mips_*|mips32*|mips64*) printf '%s\n' big; return 0 ;;
    esac

    data_byte="$(elf_data_byte 2>/dev/null || true)"
    case "$data_byte" in
        1) printf '%s\n' little; return 0 ;;
        2) printf '%s\n' big; return 0 ;;
    esac

    if has_cmd getconf; then
        byte_order="$(getconf BYTE_ORDER 2>/dev/null || true)"
        case "$byte_order" in
            1234|*LITTLE*|*little*) printf '%s\n' little; return 0 ;;
            4321|*BIG*|*big*) printf '%s\n' big; return 0 ;;
        esac
    fi
    return 1
}

arm_has_vfp() {
    cpu_features="$(sed -n 's/^[Ff]eatures[[:space:]]*:[[:space:]]*//p' "$CPUINFO_PATH" 2>/dev/null | head -n 1)"
    case " $cpu_features " in
        *" vfp "*|*" vfpv3 "*|*" vfpv4 "*) return 0 ;;
    esac
    case "$PACKAGE_ABI" in
        *hf*|arm_cortex-a*_vfp*) return 0 ;;
    esac
    return 1
}

select_asset() {
    os="$1"
    arch="$2"

    if [ "$NZ_RELEASE_TAG" != 'v2.3.5-repacked' ] || [ "$NZ_RELEASE_REPOSITORY" != 'nezha-rs/agent' ]; then
        return 1
    fi

    case "${os}:${arch}" in
        linux:amd64)
            ASSET_NAME='nezha-agent-v2.3.5-linux-x86-64-goamd64-v1-sse2-static-upx-best-lzma'
            ASSET_SIZE=5373956
            ASSET_SHA256='d943b727543ed11b0907547f66da371a532d32382728f5dedab26d34cfafc24a'
            ;;
        linux:386)
            ASSET_NAME='nezha-agent-v2.3.5-linux-x86-32-go386-sse2-static-upx-best-lzma'
            ASSET_SIZE=4667608
            ASSET_SHA256='3a906081c626ba3c07c47f6fd73856cec3e865880ecf3f0a39da15dc3cd2a8a2'
            ;;
        linux:arm5)
            ASSET_NAME='nezha-agent-v2.3.5-linux-arm-32-goarm5-software-float-no-vfp-static-custom-build-upx-best-lzma'
            ASSET_SIZE=4353796
            ASSET_SHA256='a6533ee04e6fe1cb24fc72a7c967ae043e991adddfe91e1ef61c882ddf8cd0d7'
            ;;
        linux:arm6)
            ASSET_NAME='nezha-agent-v2.3.5-linux-arm-32-goarm6-vfpv1-required-static-upx-best-lzma'
            ASSET_SIZE=4357692
            ASSET_SHA256='4ed8d95cd8f2e9f91782944dbbc1d837a875a00693a4fa195f83109d70a848ac'
            ;;
        linux:arm64)
            ASSET_NAME='nezha-agent-v2.3.5-linux-arm64-aarch64-goarm64-v8.0-static-upx-best-lzma'
            ASSET_SIZE=4397516
            ASSET_SHA256='ead85f5c0e30b73c399a58f3eb84208c9a8e1d60856a678a52cfbaa3fe3ff7d2'
            ;;
        linux:mips)
            ASSET_NAME='nezha-agent-v2.3.5-linux-mips-32-be-mips32r1-gomips-softfloat-static-upx-best-lzma'
            ASSET_SIZE=4254172
            ASSET_SHA256='18b1f214351ea5f1a8f262ed62a1e78d4866a51a43adbd4094c837b95ebffb40'
            ;;
        linux:mipsle)
            ASSET_NAME='nezha-agent-v2.3.5-linux-mips-32-le-mips32r1-gomips-softfloat-static-upx-best-lzma'
            ASSET_SIZE=4341232
            ASSET_SHA256='688c1f5e592bfdeffe7a2dbb795bcf0d4ec7b9654b5c6ce4c1ea323a65554a54'
            ;;
        linux:riscv64)
            ASSET_NAME='nezha-agent-v2.3.5-linux-riscv64-rva20u64-rv64imafd-static-upx-best-lzma'
            ASSET_SIZE=4736324
            ASSET_SHA256='4300dde63e8125068869b00ea8bbbbb324ba7622f7d29b299a782305e1387afa'
            ;;
        linux:s390x)
            ASSET_NAME='nezha-agent-v2.3.5-linux-s390x-z13-min-static-original-upx-unsupported'
            ASSET_SIZE=19071138
            ASSET_SHA256='7dc659216cc98b7fc3442e2140ff2bb9b9e525780d434f2d8853135d81386b9c'
            ;;
        linux:loong64)
            ASSET_NAME='nezha-agent-v2.3.5-linux-loongarch64-la364-min-static-original-upx-unsupported'
            ASSET_SIZE=18219170
            ASSET_SHA256='5b5e2a806963c91be4d88d8df2e57c6af0c5c635f2eeaf0d34fc55b088451eb8'
            ;;
        freebsd:amd64)
            ASSET_NAME='nezha-agent-v2.3.5-freebsd-x86-64-goamd64-v1-sse2-static-original-upx-unsupported'
            ASSET_SIZE=18026668
            ASSET_SHA256='86d10be9c0350c692a66179c20f3ecd03c912f6861fa9fc963aa341087044e96'
            ;;
        freebsd:386)
            ASSET_NAME='nezha-agent-v2.3.5-freebsd-x86-32-go386-sse2-static-original-upx-unsupported'
            ASSET_SIZE=16900268
            ASSET_SHA256='3b9b2b7daf66026b68e76038f13b383dabd12ed3be6846993b25c28392d27c8a'
            ;;
        freebsd:arm6)
            ASSET_NAME='nezha-agent-v2.3.5-freebsd-arm-32-goarm6-vfpv1-required-static-original-upx-unsupported'
            ASSET_SIZE=17039532
            ASSET_SHA256='f39d186c8ad45963d4acae9464686444f6604aa67751c7ad88a222d41cb35eeb'
            ;;
        freebsd:arm64)
            ASSET_NAME='nezha-agent-v2.3.5-freebsd-arm64-aarch64-goarm64-v8.0-static-original-upx-unsupported'
            ASSET_SIZE=16777388
            ASSET_SHA256='f79a2f8dbe78e0de74efd2ac65adc322302f19f69826021df0f3c7cf4a63aa93'
            ;;
        darwin:amd64)
            ASSET_NAME='nezha-agent-v2.3.5-darwin-x86-64-goamd64-v1-sse2-cgo0-macho'
            ASSET_SIZE=18726016
            ASSET_SHA256='ab7e439a8e07d7e1fbff72d658c9e46cf0e3483620e47e17e7fab87cfc992fdc'
            ;;
        darwin:arm64)
            ASSET_NAME='nezha-agent-v2.3.5-darwin-arm64-aarch64-goarm64-v8.0-cgo0-macho'
            ASSET_SIZE=17650370
            ASSET_SHA256='d7a13f0175c5bdc08077b54ab7a0bcc7ec20b4e9e2c3c0956e31827d294ca4f7'
            ;;
        *)
            return 1
            ;;
    esac
}

detect_platform() {
    SYSTEM="$(uname -s 2>/dev/null || true)"
    MACHINE="$(uname -m 2>/dev/null || true)"
    detect_package_abi

    OS_DETAILS=""
    if [ -r /etc/openwrt_release ]; then
        OS_DETAILS="$(sed -n 's/^DISTRIB_DESCRIPTION=//p' /etc/openwrt_release 2>/dev/null | head -n 1 | sed "s/^['\"]//;s/['\"]$//")"
    elif [ -r /etc/os-release ]; then
        OS_DETAILS="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | sed 's/^"//;s/"$//')"
    fi
    [ -n "$OS_DETAILS" ] || OS_DETAILS="$SYSTEM"

    case "$SYSTEM" in
        Linux) DETECTED_OS=linux ;;
        FreeBSD) DETECTED_OS=freebsd ;;
        Darwin) DETECTED_OS=darwin ;;
        *) die "Unsupported operating system: ${SYSTEM:-unknown}" ;;
    esac

    if [ -n "${NZ_ARCH:-}" ]; then
        case "$NZ_ARCH" in
            amd64|386|arm5|arm6|arm64|mips|mipsle|riscv64|s390x|loong64)
                DETECTED_ARCH="$NZ_ARCH"
                CPU_DETAILS="manual override NZ_ARCH=$NZ_ARCH"
                ;;
            arm)
                if arm_has_vfp; then DETECTED_ARCH=arm6; else DETECTED_ARCH=arm5; fi
                CPU_DETAILS="manual ARM override; VFP auto-detected"
                ;;
            *) die "Unsupported NZ_ARCH override: $NZ_ARCH" ;;
        esac
    else
        case "$PACKAGE_ABI" in
            x86_64*|amd64) DETECTED_ARCH=amd64 ;;
            i386*|i486*|i586*|i686*|x86) DETECTED_ARCH=386 ;;
            aarch64*|arm64*) DETECTED_ARCH=arm64 ;;
            armv5*|arm_*soft*|armel*) DETECTED_ARCH=arm5 ;;
            armv6*|armv7*|arm_cortex-a*|armhf*)
                if arm_has_vfp; then DETECTED_ARCH=arm6; else DETECTED_ARCH=arm5; fi
                ;;
            mipsel*|mipsle*) DETECTED_ARCH=mipsle ;;
            mips_*) DETECTED_ARCH=mips ;;
            riscv64*) DETECTED_ARCH=riscv64 ;;
            s390x*) DETECTED_ARCH=s390x ;;
            loongarch64*|loong64*) DETECTED_ARCH=loong64 ;;
            *) DETECTED_ARCH='' ;;
        esac

        if [ -z "$DETECTED_ARCH" ]; then
            case "$MACHINE" in
                x86_64|amd64) DETECTED_ARCH=amd64 ;;
                i386|i486|i586|i686|x86) DETECTED_ARCH=386 ;;
                aarch64|arm64|arm64v8*) DETECTED_ARCH=arm64 ;;
                armv5*) DETECTED_ARCH=arm5 ;;
                arm|armv6*|armv7*|armv8l)
                    if arm_has_vfp; then DETECTED_ARCH=arm6; else DETECTED_ARCH=arm5; fi
                    ;;
                mipsel|mipsle) DETECTED_ARCH=mipsle ;;
                mipseb) DETECTED_ARCH=mips ;;
                mips)
                    mips_endian="$(detect_mips_endian 2>/dev/null || true)"
                    case "$mips_endian" in
                        little) DETECTED_ARCH=mipsle ;;
                        big) DETECTED_ARCH=mips ;;
                        *) die "Could not determine MIPS byte order; set NZ_ARCH=mipsle or NZ_ARCH=mips." ;;
                    esac
                    ;;
                mips64*) die "64-bit MIPS is not available in ${NZ_RELEASE_TAG}." ;;
                riscv64) DETECTED_ARCH=riscv64 ;;
                s390x) DETECTED_ARCH=s390x ;;
                loongarch64|loong64) DETECTED_ARCH=loong64 ;;
                *) die "Unsupported architecture: uname -m=${MACHINE:-unknown}, package ABI=${PACKAGE_ABI:-none}." ;;
            esac
        fi

        case "$DETECTED_ARCH" in
            arm5|arm6)
                cpu_arch="$(sed -n 's/^CPU architecture[[:space:]]*:[[:space:]]*//p' "$CPUINFO_PATH" 2>/dev/null | head -n 1)"
                cpu_features="$(sed -n 's/^[Ff]eatures[[:space:]]*:[[:space:]]*//p' "$CPUINFO_PATH" 2>/dev/null | head -n 1)"
                CPU_DETAILS="ARMv${cpu_arch:-unknown}; features=${cpu_features:-unknown}; selected GOARM${DETECTED_ARCH#arm}"
                ;;
            mips|mipsle)
                CPU_DETAILS="MIPS32 softfloat; endian=${DETECTED_ARCH#mips}"
                [ "$DETECTED_ARCH" = mips ] && CPU_DETAILS="MIPS32 softfloat; endian=big"
                [ "$DETECTED_ARCH" = mipsle ] && CPU_DETAILS="MIPS32 softfloat; endian=little"
                ;;
            *) CPU_DETAILS="release baseline for $DETECTED_ARCH" ;;
        esac
    fi

    select_asset "$DETECTED_OS" "$DETECTED_ARCH" || \
        die "No ${NZ_RELEASE_TAG} binary for ${DETECTED_OS}/${DETECTED_ARCH}."

    info "Detected OS: $SYSTEM -> $DETECTED_OS"
    info "System details: $OS_DETAILS"
    info "Detected machine: $MACHINE"
    info "Detected package ABI: ${PACKAGE_ABI:-none}"
    info "Selected architecture: $DETECTED_ARCH"
    info "CPU details: $CPU_DETAILS"
    info "Selected asset: $ASSET_NAME"
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

ensure_free_space() {
    path="$1"
    required_bytes="$2"
    available_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    [ -n "$available_kb" ] || return 0
    required_kb=$(( (required_bytes + 1048575) / 1024 + 1024 ))
    [ "$available_kb" -ge "$required_kb" ] || \
        die "Not enough free space at $path: need at least ${required_kb} KiB, have ${available_kb} KiB."
}

sha256_file() {
    file="$1"
    if has_cmd sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif has_cmd shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif has_cmd openssl; then
        openssl dgst -sha256 "$file" | sed 's/^.*= //'
    elif has_cmd busybox && busybox sha256sum --help >/dev/null 2>&1; then
        busybox sha256sum "$file" | awk '{print $1}'
    else
        return 1
    fi
}

verify_binary_header() {
    file="$1"
    has_cmd od || return 0
    header="$(od -An -tx1 -N20 "$file" 2>/dev/null | tr -d ' \n')"

    case "$DETECTED_OS" in
        linux|freebsd)
            case "$header" in 7f454c46*) ;; *) return 1 ;; esac
            elf_class="$(printf '%s' "$header" | cut -c9-10)"
            elf_data="$(printf '%s' "$header" | cut -c11-12)"
            elf_machine="$(printf '%s' "$header" | cut -c37-40)"
            case "$DETECTED_ARCH" in
                amd64) [ "$elf_class:$elf_data:$elf_machine" = '02:01:3e00' ] ;;
                386) [ "$elf_class:$elf_data:$elf_machine" = '01:01:0300' ] ;;
                arm5|arm6) [ "$elf_class:$elf_data:$elf_machine" = '01:01:2800' ] ;;
                arm64) [ "$elf_class:$elf_data:$elf_machine" = '02:01:b700' ] ;;
                mipsle) [ "$elf_class:$elf_data:$elf_machine" = '01:01:0800' ] ;;
                mips) [ "$elf_class:$elf_data:$elf_machine" = '01:02:0008' ] ;;
                riscv64) [ "$elf_class:$elf_data:$elf_machine" = '02:01:f300' ] ;;
                s390x) [ "$elf_class:$elf_data:$elf_machine" = '02:02:0016' ] ;;
                loong64) [ "$elf_class:$elf_data:$elf_machine" = '02:01:0201' ] ;;
                *) return 1 ;;
            esac
            ;;
        darwin)
            case "$DETECTED_ARCH:$header" in
                amd64:cffaedfe*) return 0 ;;
                arm64:cffaedfe*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

verify_download() {
    actual_size="$(file_size "$TEMP_BINARY")"
    [ "$actual_size" = "$ASSET_SIZE" ] || \
        die "Downloaded size mismatch: expected $ASSET_SIZE bytes, got ${actual_size:-unknown}."

    actual_sha256="$(sha256_file "$TEMP_BINARY" 2>/dev/null || true)"
    [ -n "$actual_sha256" ] || die "SHA-256 tool is required: sha256sum, shasum, or openssl."
    [ "$actual_sha256" = "$ASSET_SHA256" ] || \
        die "SHA-256 mismatch: expected $ASSET_SHA256, got $actual_sha256."

    verify_binary_header "$TEMP_BINARY" || \
        die "Binary header does not match detected platform ${DETECTED_OS}/${DETECTED_ARCH}."

    chmod +x "$TEMP_BINARY" || die "Could not make the downloaded binary executable."
    version_output="$("$TEMP_BINARY" --version 2>&1)"
    version_exit=$?
    if [ "$version_exit" -ne 0 ]; then
        die "Downloaded binary failed its runtime test (exit $version_exit): $version_output"
    fi
    case "$version_output" in
        *' version 2.3.5'*) ;;
        *) die "Unexpected binary version output: $version_output" ;;
    esac
    info "Verified size: $actual_size bytes"
    info "Verified SHA-256: $actual_sha256"
    info "Runtime test: $version_output"
}

choose_config_path() {
    path="$NZ_AGENT_PATH/config.yml"
    if [ -f "$path" ]; then
        if [ -r /dev/urandom ] && has_cmd od; then
            suffix="$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        else
            suffix="$$"
        fi
        path="$NZ_AGENT_PATH/config-${suffix}.yml"
    fi
    printf '%s\n' "$path"
}

install_agent() {
    [ -n "${NZ_SERVER:-}" ] || die "NZ_SERVER must not be empty."
    [ -n "${NZ_CLIENT_SECRET:-}" ] || die "NZ_CLIENT_SECRET must not be empty."

    detect_platform
    download_url="${NZ_RELEASE_BASE}/${ASSET_NAME}"
    info "Downloading from: $download_url"
    rm -f "$TEMP_BINARY"
    ensure_free_space "${TMPDIR:-/tmp}" "$ASSET_SIZE"
    download_to "$download_url" "$TEMP_BINARY" || die "Binary download failed: $download_url"
    verify_download

    run_as_root mkdir -p "$NZ_AGENT_PATH" || die "Could not create $NZ_AGENT_PATH."
    ensure_free_space "$NZ_AGENT_PATH" "$ASSET_SIZE"
    target_binary="$NZ_AGENT_PATH/nezha-agent"
    backup_binary="$NZ_AGENT_PATH/nezha-agent.backup"
    if run_as_root test -f "$target_binary"; then
        run_as_root cp -f "$target_binary" "$backup_binary" || die "Could not back up existing agent."
        info "Existing agent backed up to: $backup_binary"
    fi
    run_as_root cp -f "$TEMP_BINARY" "$target_binary" || die "Could not install the verified binary."
    run_as_root chmod 755 "$target_binary" || die "Could not set executable permissions."
    cleanup

    path="$(choose_config_path)"
    run_as_root "$target_binary" service -c "$path" uninstall >/dev/null 2>&1 || true

    info "Installing service with config: $path"
    if ! run_as_root env \
        "NZ_UUID=${NZ_UUID:-}" \
        "NZ_SERVER=$NZ_SERVER" \
        "NZ_CLIENT_SECRET=$NZ_CLIENT_SECRET" \
        "NZ_TLS=${NZ_TLS:-false}" \
        "NZ_DISABLE_AUTO_UPDATE=${NZ_DISABLE_AUTO_UPDATE:-true}" \
        "NZ_DISABLE_FORCE_UPDATE=${NZ_DISABLE_FORCE_UPDATE:-${DISABLE_FORCE_UPDATE:-false}}" \
        "NZ_DISABLE_COMMAND_EXECUTE=${NZ_DISABLE_COMMAND_EXECUTE:-false}" \
        "NZ_SKIP_CONNECTION_COUNT=${NZ_SKIP_CONNECTION_COUNT:-false}" \
        "$target_binary" service -c "$path" install >> "$LOG_FILE" 2>&1; then
        run_as_root "$target_binary" service -c "$path" uninstall >/dev/null 2>&1 || true
        if run_as_root test -f "$backup_binary"; then
            run_as_root cp -f "$backup_binary" "$target_binary" || true
        fi
        die "Nezha Agent service installation failed. See the log included in the Telegram notification."
    fi

    success "Nezha Agent installed successfully."
    notify_result success
    rm -f "$LOG_FILE"
}

check_download() {
    detect_platform
    download_url="${NZ_RELEASE_BASE}/${ASSET_NAME}"
    info "Downloading from: $download_url"
    rm -f "$TEMP_BINARY"
    ensure_free_space "${TMPDIR:-/tmp}" "$ASSET_SIZE"
    download_to "$download_url" "$TEMP_BINARY" || die "Binary download failed: $download_url"
    verify_download
    success "Download verification completed; no system files were changed."
    cleanup
    rm -f "$LOG_FILE"
}

uninstall_agent() {
    found=0
    for file in "$NZ_AGENT_PATH"/config*.yml; do
        [ -f "$file" ] || continue
        found=1
        run_as_root "$NZ_AGENT_PATH/nezha-agent" service -c "$file" uninstall || true
        run_as_root rm -f "$file" || true
    done
    [ "$found" = 1 ] || info "No installed configuration files were found."
    success "Uninstallation completed."
}

: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

case "${1:-}" in
    uninstall)
        uninstall_agent
        ;;
    --detect|detect)
        detect_platform
        info "Asset size: $ASSET_SIZE bytes"
        info "Asset SHA-256: $ASSET_SHA256"
        ;;
    --check-download)
        check_download
        ;;
    --help|-h)
        cat <<'EOF'
Usage:
  env NZ_SERVER=host:port NZ_CLIENT_SECRET=secret [NZ_TLS=false] sh agent.sh
  sh agent.sh --detect
  sh agent.sh --check-download
  sh agent.sh uninstall

Optional environment variables:
  NZ_UUID, NZ_ARCH, NZ_BASE_PATH, NZ_AGENT_PATH
  NZ_DISABLE_AUTO_UPDATE, NZ_DISABLE_FORCE_UPDATE
  NZ_DISABLE_COMMAND_EXECUTE, NZ_SKIP_CONNECTION_COUNT
  TG_BOT_TOKEN, TG_CHAT_ID

NZ_ARCH values: amd64, 386, arm5, arm6, arm64, mips, mipsle,
                riscv64, s390x, loong64
EOF
        ;;
    '')
        install_agent
        ;;
    *)
        die "Unknown option: $1"
        ;;
esac
