#!/usr/bin/env bash
# Bash 5.3+ | Arch Linux | UEFI + Btrfs root + Limine base setup
set -Eeuo pipefail
export LC_ALL=C
umask 022

trap 'rc=$?; printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

fatal() {
    printf 'FATAL: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || fatal "Input closed."
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then
            printf 'Skipped.\n'
            return 0
        fi
        "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

if [[ "$EUID" -eq 0 ]]; then
    fatal "Run this script as a regular user with sudo access, not as root."
fi

sudo -v || fatal "Cannot obtain sudo privileges."
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
cleanup() {
    kill "$SUDO_PID" 2>/dev/null || true
}
trap cleanup EXIT

[[ -d /sys/firmware/efi ]] || fatal "System is not booted in UEFI mode."
[[ "$(stat -f -c %T /)" == "btrfs" ]] || fatal "Root filesystem is not Btrfs."

require_command findmnt
require_command awk
require_command sed
require_command grep
require_command blkid
require_command vercmp

get_root_source() {
    local source
    source="$(findmnt -no SOURCE /)"
    source="${source%%\[*}"
    printf '%s\n' "$source"
}

get_mount_option_value() {
    local options="$1"
    local key="$2"
    local part
    IFS=',' read -r -a parts <<< "$options"
    for part in "${parts[@]}"; do
        [[ "$part" == "${key}="* ]] && {
            printf '%s\n' "${part#*=}"
            return 0
        }
    done
    return 1
}

sanitize_rootflags_options() {
    local options="$1"
    local part
    local -a out=()

    IFS=',' read -r -a parts <<< "$options"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|rw|ro|subvolid=*)
                continue
                ;;
            *)
                out+=("$part")
                ;;
        esac
    done

    local IFS=','
    printf '%s\n' "${out[*]}"
}

append_unique() {
    local -n arr_ref="$1"
    local value="$2"
    local existing
    for existing in "${arr_ref[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    arr_ref+=("$value")
}

read_effective_mkinitcpio_hooks() {
    bash -c '
        set -Eeuo pipefail
        shopt -s nullglob
        source /etc/mkinitcpio.conf
        for f in /etc/mkinitcpio.conf.d/*.conf; do
            source "$f"
        done
        printf "%s\n" "${HOOKS[*]}"
    '
}

collect_preserved_cmdline_args() {
    local token
    while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        case "$token" in
            BOOT_IMAGE=*|initrd=*|root=*|rootflags=*|cryptdevice=*|rd.luks.name=*|rd.luks.uuid=*|rw|ro|mitigations=*|audit=*|nowatchdog|nmi_watchdog=*)
                continue
                ;;
            *)
                printf '%s\n' "$token"
                ;;
        esac
    done < <(tr ' ' '\n' < /proc/cmdline)
}

detect_esp_mountpoint() {
    local candidate fstype
    for candidate in /efi /boot /boot/efi; do
        fstype="$(findmnt -rn -o FSTYPE --target "$candidate" 2>/dev/null || true)"
        case "$fstype" in
            vfat|fat|msdos)
                printf '%s\n' "$candidate"
                return 0
                ;;
        esac
    done
    fatal "Could not find a mounted ESP at /efi, /boot, or /boot/efi."
}

install_core_repo_packages() {
    sudo pacman -S --needed --noconfirm \
        limine \
        efibootmgr \
        snapper \
        snap-pac \
        kernel-modules-hook \
        btrfs-progs \
        git \
        base-devel
}

install_matching_kernel_headers() {
    local -a headers=()
    pacman -Q linux >/dev/null 2>&1 && headers+=(linux-headers)
    pacman -Q linux-lts >/dev/null 2>&1 && headers+=(linux-lts-headers)
    pacman -Q linux-zen >/dev/null 2>&1 && headers+=(linux-zen-headers)
    pacman -Q linux-hardened >/dev/null 2>&1 && headers+=(linux-hardened-headers)

    if (( ${#headers[@]} > 0 )); then
        sudo pacman -S --needed --noconfirm "${headers[@]}"
    fi
}

configure_kernel_cmdline() {
    local root_source root_options rootflags root_uuid hooks
    local mapper_name backing_dev luks_uuid
    local -a microcode_args=()
    local -a cmdline_args=()
    local -a preserved_args=()
    local -a final_args=()
    local token
    local cmdline=""

    root_source="$(get_root_source)"
    root_options="$(findmnt -no OPTIONS /)"
    rootflags="$(sanitize_rootflags_options "$root_options")"
    hooks="$(read_effective_mkinitcpio_hooks)"

    cmdline_args=(rw)

    if sudo cryptsetup status "$root_source" >/dev/null 2>&1; then
        mapper_name="${root_source##*/}"
        backing_dev="$(sudo cryptsetup status "$root_source" | awk '$1=="device:" {print $2}')"
        [[ -n "$backing_dev" ]] || fatal "Could not determine the backing device for $root_source."
        luks_uuid="$(sudo blkid -s UUID -o value "$backing_dev")"
        [[ -n "$luks_uuid" ]] || fatal "Could not determine the LUKS UUID."

        if [[ " $hooks " == *" sd-encrypt "* ]]; then
            append_unique cmdline_args "rd.luks.name=${luks_uuid}=${mapper_name}"
            append_unique cmdline_args "root=/dev/mapper/${mapper_name}"
        elif [[ " $hooks " == *" encrypt "* ]]; then
            append_unique cmdline_args "cryptdevice=UUID=${luks_uuid}:${mapper_name}"
            append_unique cmdline_args "root=/dev/mapper/${mapper_name}"
        else
            fatal "Root is on LUKS, but neither encrypt nor sd-encrypt is active in mkinitcpio HOOKS."
        fi
    else
        root_uuid="$(findmnt -no UUID /)"
        [[ -n "$root_uuid" ]] || root_uuid="$(sudo blkid -s UUID -o value "$root_source")"
        [[ -n "$root_uuid" ]] || fatal "Could not determine the root filesystem UUID."
        append_unique cmdline_args "root=UUID=${root_uuid}"
    fi

    if [[ -n "$rootflags" ]]; then
        append_unique cmdline_args "rootflags=${rootflags}"
    fi

    if [[ " $hooks " != *" microcode "* ]]; then
        shopt -s nullglob
        for img in /boot/*-ucode.img; do
            microcode_args+=("initrd=/$(basename "$img")")
        done
        shopt -u nullglob
    fi

    while IFS= read -r token; do
        append_unique preserved_args "$token"
    done < <(collect_preserved_cmdline_args)

    final_args=("${microcode_args[@]}" "${cmdline_args[@]}" "${preserved_args[@]}")

    for token in "${final_args[@]}"; do
        [[ -n "$token" ]] && cmdline+="${token} "
    done
    cmdline="${cmdline% }"

    sudo install -d -m 0755 /etc/kernel
    printf '%s\n' "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
    info "Wrote /etc/kernel/cmdline"
}

configure_limine_defaults() {
    local esp_path file
    esp_path="$(detect_esp_mountpoint)"
    file="/etc/default/limine"

    sudo install -d -m 0755 /etc/default
    if [[ ! -f "$file" ]]; then
        if [[ -f /etc/limine-entry-tool.conf ]]; then
            sudo cp /etc/limine-entry-tool.conf "$file"
        else
            sudo touch "$file"
        fi
    fi

    if sudo grep -qE '^[[:space:]#]*ESP_PATH=' "$file"; then
        sudo sed -i -E "s|^[[:space:]#]*ESP_PATH=.*|ESP_PATH=\"${esp_path}\"|" "$file"
    else
        printf 'ESP_PATH="%s"\n' "$esp_path" | sudo tee -a "$file" >/dev/null
    fi

    info "Set ESP_PATH to ${esp_path} in /etc/default/limine"
}

aur_pkg_version() {
    local repo_dir="$1"
    awk -F ' = ' '
        $1 == "epoch"  { epoch=$2 }
        $1 == "pkgver" { pkgver=$2 }
        $1 == "pkgrel" { pkgrel=$2 }
        END {
            if (pkgver == "" || pkgrel == "") exit 1
            if (epoch != "" && epoch != "0") {
                printf "%s:%s-%s\n", epoch, pkgver, pkgrel
            } else {
                printf "%s-%s\n", pkgver, pkgrel
            }
        }
    ' "${repo_dir}/.SRCINFO"
}

install_or_upgrade_aur_pkg() {
    local pkg="$1"
    local tmp_dir repo_dir aur_version installed_version cmp

    require_command git
    require_command makepkg

    tmp_dir="$(mktemp -d)"
    repo_dir="${tmp_dir}/${pkg}"

    git clone --depth=1 "https://aur.archlinux.org/${pkg}.git" "$repo_dir" >/dev/null 2>&1 || {
        rm -rf "$tmp_dir"
        fatal "Failed to clone AUR repo for ${pkg}."
    }

    aur_version="$(aur_pkg_version "$repo_dir")" || {
        rm -rf "$tmp_dir"
        fatal "Failed to read AUR version for ${pkg}."
    }

    if pacman -Q "$pkg" >/dev/null 2>&1; then
        installed_version="$(pacman -Q "$pkg" | awk '{print $2}')"
        cmp="$(vercmp "$installed_version" "$aur_version")"
        if (( cmp >= 0 )); then
            info "${pkg} ${installed_version} is already installed."
            rm -rf "$tmp_dir"
            return 0
        fi
    fi

    (
        cd "$repo_dir"
        makepkg -sri --noconfirm --needed --cleanbuild
    )

    rm -rf "$tmp_dir"
}

install_aur_packages() {
    install_or_upgrade_aur_pkg limine-snapper-sync
    install_or_upgrade_aur_pkg limine-mkinitcpio-hook
}

dedupe_limine_boot_entries() {
    local -a native_ids=()
    local -a fallback_ids=()
    local i

    mapfile -t native_ids < <(
        sudo efibootmgr -v | awk '
            BEGIN { IGNORECASE=1 }
            /^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F][* ]/ && /\\EFI\\limine\\limine_x64\.efi/ {
                print substr($1, 5, 4)
            }
        '
    )

    mapfile -t fallback_ids < <(
        sudo efibootmgr -v | awk '
            BEGIN { IGNORECASE=1 }
            /^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F][* ]/ && /Limine/ && /\\EFI\\BOOT\\BOOTX64\.EFI/ {
                print substr($1, 5, 4)
            }
        '
    )

    if (( ${#native_ids[@]} > 1 )); then
        for (( i=1; i<${#native_ids[@]}; i++ )); do
            sudo efibootmgr -b "${native_ids[$i]}" -B >/dev/null 2>&1 || warn "Could not delete duplicate native Limine EFI entry ${native_ids[$i]}."
        done
    fi

    if (( ${#native_ids[@]} >= 1 && ${#fallback_ids[@]} >= 1 )); then
        for i in "${fallback_ids[@]}"; do
            sudo efibootmgr -b "$i" -B >/dev/null 2>&1 || warn "Could not delete fallback Limine EFI entry ${i}."
        done
    fi
}

ensure_limine_deployed() {
    local esp_path native_binary
    local have_native_entry=false

    require_command limine-install
    require_command limine-update
    require_command efibootmgr

    esp_path="$(detect_esp_mountpoint)"
    native_binary="${esp_path%/}/EFI/limine/limine_x64.efi"

    if sudo efibootmgr -v | grep -Eiq '\\EFI\\limine\\limine_x64\.efi'; then
        have_native_entry=true
    fi

    if [[ ! -f "$native_binary" || "$have_native_entry" == false ]]; then
        sudo limine-install
    fi

    sudo limine-update
    dedupe_limine_boot_entries
    info "Limine deployment and update completed."
}

execute "Install official repository packages" install_core_repo_packages
execute "Install matching kernel headers for stock Arch kernels" install_matching_kernel_headers
execute "Generate /etc/kernel/cmdline from the live system" configure_kernel_cmdline
execute "Configure /etc/default/limine" configure_limine_defaults
execute "Install required AUR packages without an AUR helper" install_aur_packages
execute "Deploy and refresh Limine" ensure_limine_deployed
