#!/usr/bin/env bash
# Bash 5.3+ | V2 Core Architecture: Limine + Mkinitcpio Integration
set -Eeuo pipefail
export LC_ALL=C
trap 'printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; trap - ERR' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || { echo "FATAL: Cannot obtain sudo privileges." >&2; exit 1; }
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

# Strict Pre-flight Checks
[[ -d /sys/firmware/efi ]] || { echo "FATAL: System is not booted in EFI mode." >&2; exit 1; }
[[ "$(stat -f -c %T /)" == "btrfs" ]] || { echo "FATAL: Root filesystem is not BTRFS." >&2; exit 1; }

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || { printf '\nInput closed; aborting.\n' >&2; exit 1; }
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then echo "Skipped."; return 0; fi
        "$@"
    fi
}

install_packages() {
    sudo pacman -S --needed --noconfirm limine efibootmgr snapper snap-pac kernel-modules-hook
    
    local aur_helper=""
    if command -v paru &>/dev/null; then aur_helper="paru";
    elif command -v yay &>/dev/null; then aur_helper="yay"; fi
    
    [[ -n "$aur_helper" ]] || { echo "FATAL: No AUR helper (yay/paru) found." >&2; return 1; }
    
    "$aur_helper" -S --needed --noconfirm limine-snapper-sync limine-mkinitcpio-hook
}
execute "Install core snapshot and AUR orchestrator packages" install_packages

configure_cmdline() {
    local root_part mount_opts root_subvol
    root_part=$(findmnt -fno SOURCE / | sed 's/\[.*\]//')
    mount_opts=$(findmnt -fno OPTIONS /)
    root_subvol=$(echo "$mount_opts" | grep -oP 'subvol=/?\K[^,]+' || echo "@")

    local luks_uuid=""
    local mapper_name=""
    local kernel_cmdline="quiet loglevel=3 splash rw rootflags=subvol=${root_subvol} nowatchdog nmi_watchdog=0 mitigations=off audit=0"

    local effective_hooks_line
    effective_hooks_line=$(cat /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf 2>/dev/null | grep -E '^\s*HOOKS\s*=' | tail -n1 || true)

    if [[ "$root_part" == /dev/mapper/* ]]; then
        mapper_name="${root_part##*/}"
        local backing_dev
        backing_dev=$(sudo cryptsetup status "$root_part" | awk '/device:/ {print $2}')
        luks_uuid=$(sudo blkid -s UUID -o value "$backing_dev" || true)
        
        [[ -n "$luks_uuid" ]] || { echo "FATAL: Could not determine LUKS UUID." >&2; return 1; }
        
        if [[ " $effective_hooks_line " == *" sd-encrypt "* ]]; then
            kernel_cmdline+=" rd.luks.name=${luks_uuid}=${mapper_name} root=/dev/mapper/${mapper_name}"
        elif [[ " $effective_hooks_line " == *" encrypt "* ]]; then
            kernel_cmdline+=" cryptdevice=UUID=${luks_uuid}:${mapper_name} root=/dev/mapper/${mapper_name}"
        else
            echo "FATAL: Root is LUKS but no encrypt/sd-encrypt hook found." >&2
            return 1
        fi
    else
        local root_uuid
        root_uuid=$(sudo blkid -s UUID -o value "$root_part")
        kernel_cmdline+=" root=UUID=${root_uuid}"
    fi

    # Native Microcode mapping
    if [[ ! " $effective_hooks_line " == *" microcode "* ]]; then
        shopt -s nullglob
        for img in /boot/*-ucode.img; do
            kernel_cmdline+=" initrd=/$(basename "$img")"
        done
        shopt -u nullglob
    fi

    sudo mkdir -p /etc/kernel
    echo "$kernel_cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
    echo "Successfully generated native /etc/kernel/cmdline"
}
execute "Generate native Kernel Command Line" configure_cmdline

configure_limine_defaults() {
    if [[ -f /etc/limine-entry-tool.conf && ! -f /etc/default/limine ]]; then
        sudo cp /etc/limine-entry-tool.conf /etc/default/limine
    fi
    
    local esp_target
    esp_target=$(findmnt -fno TARGET /boot || findmnt -fno TARGET /efi || echo "/boot")
    
    if grep -q "^#*ESP_PATH=" /etc/default/limine 2>/dev/null; then
        sudo sed -i "s|^#*ESP_PATH=.*|ESP_PATH=\"${esp_target}\"|" /etc/default/limine
    else
        echo "ESP_PATH=\"${esp_target}\"" | sudo tee -a /etc/default/limine >/dev/null
    fi
}
execute "Configure /etc/default/limine paths" configure_limine_defaults

deploy_native_limine() {
    echo "Installing Limine EFI binary and registering NVRAM..."
    sudo limine-install --fallback || true
    sudo limine-install
    
    echo "Generating mkinitcpio and auto-populating /boot/limine.conf..."
    sudo limine-update
}
execute "Deploy Limine using native AUR orchestrator" deploy_native_limine
