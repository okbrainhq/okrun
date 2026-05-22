#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ./scripts/bootstrap-imported-vm.sh <hostname-or-ip>

Interactive first-run bootstrapper for an imported Ubuntu VM.
It asks for all selections first, then SSHes into the VM and applies them.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix='[y/N]'
  local answer

  if [ "$default" = "y" ]; then
    suffix='[Y/n]'
  fi

  while true; do
    read -r -p "$prompt $suffix: " answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' ;;
    esac
  done
}

validate_username() {
  local value="$1"
  [[ "$value" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]
}

validate_hostname() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

choose_public_key() {
  local keys=()
  local key
  local i
  local choice
  local fingerprint

  if [ -d "$HOME/.ssh" ]; then
    while IFS= read -r key; do
      keys+=("$key")
    done < <(find "$HOME/.ssh" -maxdepth 1 -type f -name '*.pub' | sort)
  fi

  if [ "${#keys[@]}" -eq 0 ]; then
    printf 'No public keys were found in %s/.ssh.\n' "$HOME" >&2
    while true; do
      read -r -p "Path to an SSH public key: " key
      [ -n "$key" ] || continue
      [ -f "$key" ] || {
        printf 'That file does not exist.\n' >&2
        continue
      }
      printf '%s' "$key"
      return 0
    done
  fi

  printf '\nAvailable SSH public keys:\n' >&2
  for ((i = 0; i < ${#keys[@]}; i++)); do
    fingerprint="$(ssh-keygen -lf "${keys[$i]}" 2>/dev/null || true)"
    printf '  %d) %s\n' "$((i + 1))" "${keys[$i]}" >&2
    if [ -n "$fingerprint" ]; then
      printf '     %s\n' "$fingerprint" >&2
    fi
  done

  while true; do
    read -r -p "Select key [1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
      printf '%s' "${keys[$((choice - 1))]}"
      return 0
    fi
    printf 'Please enter a number from 1 to %d.\n' "${#keys[@]}" >&2
  done
}

run_with_expect_password() {
  local password="$1"
  shift

  expect -f - -- "$password" "$@" <<'EXPECT_SCRIPT'
set timeout -1
set password [lindex $argv 0]
set cmd [lrange $argv 1 end]

spawn {*}$cmd
expect {
  -re {(?i)are you sure you want to continue connecting.*\?} {
    send -- "yes\r"
    exp_continue
  }
  -re {(?i)password.*:} {
    send -- "$password\r"
    exp_continue
  }
  eof
}

catch wait result
set exit_code [lindex $result 3]
if {$exit_code eq ""} {
  set exit_code 1
}
exit $exit_code
EXPECT_SCRIPT
}

create_remote_script() {
  local output="$1"

  cat > "$output" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

old_user="$1"
new_user="$2"
new_hostname="$3"
public_key_b64="$4"
lock_old_user="$5"
system_hostname="$new_hostname"

if [[ "$system_hostname" == *.local ]]; then
  system_hostname="${system_hostname%.local}"
fi

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

validate_username() {
  local value="$1"
  [[ "$value" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]
}

validate_hostname() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

set_sshd_option() {
  local option="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"
  local tmp

  [ -f "$file" ] || die "$file does not exist"
  tmp="$(mktemp)"

  awk -v option="$option" -v value="$value" '
    BEGIN {
      done = 0
      option_lower = tolower(option)
    }
    {
      raw = $0
      line = $0
      sub(/^[[:space:]]+/, "", line)
      candidate = line
      if (substr(candidate, 1, 1) == "#") {
        candidate = substr(candidate, 2)
        sub(/^[[:space:]]+/, "", candidate)
      }
      split(candidate, parts, /[[:space:]]+/)
      if (tolower(parts[1]) == option_lower) {
        if (!done) {
          print option " " value
          done = 1
        }
        next
      }
      print raw
    }
    END {
      if (!done) {
        print option " " value
      }
    }
  ' "$file" > "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

reload_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null && return 0
    systemctl restart ssh 2>/dev/null && return 0
  fi

  if command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null && return 0
    service ssh restart 2>/dev/null && return 0
  fi

  die "could not reload or restart the ssh service"
}

restart_optional_service() {
  local service_name="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$service_name" 2>/dev/null && return 0
  fi

  if command -v service >/dev/null 2>&1; then
    service "$service_name" restart 2>/dev/null && return 0
  fi

  return 1
}

regenerate_machine_identity() {
  log "Regenerating clone-specific machine identity"

  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id

  if command -v systemd-machine-id-setup >/dev/null 2>&1; then
    systemd-machine-id-setup >/dev/null
  elif command -v dbus-uuidgen >/dev/null 2>&1; then
    dbus-uuidgen > /etc/machine-id
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
  else
    date +%s%N | sha256sum | awk '{print substr($1, 1, 32)}' > /etc/machine-id
  fi

  chmod 444 /etc/machine-id
  if [ -d /var/lib/dbus ]; then
    ln -sf /etc/machine-id /var/lib/dbus/machine-id
  fi
}

clear_dhcp_clone_state() {
  log "Clearing cloned DHCP lease state"

  rm -f /var/lib/systemd/network/* 2>/dev/null || true
  rm -f /run/systemd/netif/leases/* 2>/dev/null || true
  rm -f /var/lib/NetworkManager/*lease* 2>/dev/null || true
  rm -f /var/lib/dhcp/*lease* 2>/dev/null || true
}

regenerate_ssh_host_keys() {
  log "Regenerating SSH host keys"

  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
}

schedule_reboot() {
  log "Scheduling reboot to activate the unique DHCP and mDNS identity"

  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --on-active=5 --unit=okrun-post-bootstrap-reboot /usr/bin/env systemctl reboot >/dev/null 2>&1 && return 0
  fi

  nohup sh -c 'sleep 5; if command -v systemctl >/dev/null 2>&1; then systemctl reboot; else reboot; fi' >/dev/null 2>&1 &
}

[ "$(id -u)" -eq 0 ] || die "remote script must run as root"
validate_username "$old_user" || die "invalid current username: $old_user"
validate_username "$new_user" || die "invalid new username: $new_user"
validate_hostname "$new_hostname" || die "invalid hostname: $new_hostname"
validate_hostname "$system_hostname" || die "invalid system hostname derived from: $new_hostname"
id "$old_user" >/dev/null 2>&1 || die "current user '$old_user' does not exist"

public_key="$(printf '%s' "$public_key_b64" | base64 -d)"
case "$public_key" in
  ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|sk-ecdsa-*\ *) ;;
  *) die "selected public key does not look like an SSH public key" ;;
esac

old_home="$(getent passwd "$old_user" | cut -d: -f6)"
old_shell="$(getent passwd "$old_user" | cut -d: -f7)"
[ -n "$old_shell" ] || old_shell="/bin/bash"

log "Running apt update"
apt-get update

log "Running apt upgrade"
DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  upgrade

regenerate_machine_identity
clear_dhcp_clone_state

log "Creating or updating login user '$new_user'"
if id "$new_user" >/dev/null 2>&1; then
  printf "User '%s' already exists; reusing it.\n" "$new_user"
else
  adduser --disabled-password --gecos "" --shell "$old_shell" "$new_user"
fi

new_home="$(getent passwd "$new_user" | cut -d: -f6)"
new_group="$(id -gn "$new_user")"

if [ "$old_user" != "$new_user" ] && [ -d "$old_home" ] && [ -d "$new_home" ]; then
  log "Copying home directory defaults from '$old_user' to '$new_user'"
  (
    cd "$old_home"
    tar --exclude='./.ssh/authorized_keys' --exclude='./.ssh/authorized_keys2' -cpf - .
  ) | (
    cd "$new_home"
    tar -xpf -
  )
  chown -R "$new_user:$new_group" "$new_home"
fi

old_groups="$(id -nG "$old_user" | tr ' ' '\n' | grep -vx "$old_user" | paste -sd, - || true)"
if [ -n "$old_groups" ]; then
  usermod -aG "$old_groups" "$new_user"
fi
usermod -aG sudo "$new_user"

log "Installing selected SSH public key for '$new_user'"
install -d -m 700 -o "$new_user" -g "$new_group" "$new_home/.ssh"
authorized_keys="$new_home/.ssh/authorized_keys"
touch "$authorized_keys"
chown "$new_user:$new_group" "$authorized_keys"
chmod 600 "$authorized_keys"
if ! grep -qxF "$public_key" "$authorized_keys"; then
  printf '%s\n' "$public_key" >> "$authorized_keys"
fi
chown "$new_user:$new_group" "$authorized_keys"

log "Enabling passwordless sudo for '$new_user'"
sudoers_file="/etc/sudoers.d/90-${new_user}-nopasswd"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$new_user" > "$sudoers_file"
chmod 440 "$sudoers_file"
visudo -cf "$sudoers_file" >/dev/null

log "Changing hostname to '$system_hostname'"
hostnamectl set-hostname "$system_hostname"
hosts_names="$system_hostname"
if [ "$new_hostname" != "$system_hostname" ]; then
  hosts_names="$system_hostname $new_hostname"
fi
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${hosts_names}/" /etc/hosts
else
  printf '127.0.1.1 %s\n' "$hosts_names" >> /etc/hosts
fi

if [ -f /etc/cloud/cloud.cfg ]; then
  if grep -qE '^preserve_hostname:' /etc/cloud/cloud.cfg; then
    sed -i -E 's/^preserve_hostname:.*/preserve_hostname: true/' /etc/cloud/cloud.cfg
  else
    printf '\npreserve_hostname: true\n' >> /etc/cloud/cloud.cfg
  fi
fi

log "Disabling SSH password authentication"
if [ -d /etc/ssh/sshd_config.d ]; then
  cat > /etc/ssh/sshd_config.d/99-disable-password-auth.conf <<'SSHD_DROPIN'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD_DROPIN
fi

set_sshd_option PasswordAuthentication no
set_sshd_option KbdInteractiveAuthentication no
set_sshd_option ChallengeResponseAuthentication no
set_sshd_option PubkeyAuthentication yes
set_sshd_option PermitRootLogin prohibit-password
regenerate_ssh_host_keys

if command -v sshd >/dev/null 2>&1; then
  sshd -t
elif [ -x /usr/sbin/sshd ]; then
  /usr/sbin/sshd -t
else
  die "could not find sshd to validate config"
fi
reload_ssh

if [ "$old_user" != "$new_user" ] && [ "$lock_old_user" = "1" ]; then
  log "Locking original account '$old_user'"
  passwd -l "$old_user" >/dev/null || true
  chage -E 1 "$old_user"
fi

restart_optional_service avahi-daemon || true
schedule_reboot

log "Done"
printf 'Try logging in with: ssh %s@%s\n' "$new_user" "$new_hostname"
REMOTE_SCRIPT
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

target="$1"
current_user="user"
current_password="password"
ssh_port="22"

command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v scp >/dev/null 2>&1 || die "scp is required"
command -v expect >/dev/null 2>&1 || die "expect is required for automatic password handling"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
command -v base64 >/dev/null 2>&1 || die "base64 is required"

printf 'No remote commands will run until you confirm the final plan.\n\n'
printf 'Using default VM SSH login: %s@%s:%s\n\n' "$current_user" "$target" "$ssh_port"

while true; do
  new_username="$(prompt_default "New login username" "ubuntu")"
  validate_username "$new_username" && break
  printf 'Use a lowercase Linux username such as arunoda or vm_admin.\n'
done

while true; do
  new_hostname="$(prompt_default "New hostname" "ubuntu-vm")"
  validate_hostname "$new_hostname" && break
  printf 'Use a valid hostname such as ubuntu-vm or vm01.local.\n'
done

selected_key="$(choose_public_key)"
if ! ssh-keygen -lf "$selected_key" >/dev/null 2>&1; then
  die "selected key is not a valid SSH public key: $selected_key"
fi

lock_old_user=1

public_key_b64="$(base64 < "$selected_key" | tr -d '\n')"

printf '\nPlan:\n'
printf '  Target:              %s\n' "$target"
printf '  SSH login:           %s@%s:%s\n' "$current_user" "$target" "$ssh_port"
printf '  SSH port:            %s\n' "$ssh_port"
printf '  Password handling:   automatic via expect\n'
printf '  New login user:      %s\n' "$new_username"
printf '  New hostname:        %s\n' "$new_hostname"
printf '  Authorized key:      %s\n' "$selected_key"
if [ "$current_user" != "$new_username" ]; then
  printf '  Original account:    lock after setup\n'
else
  printf '  Original account:    unchanged\n'
fi

cat <<'PLAN'

Remote actions:
  - Run apt-get update and apt-get -y upgrade
  - Create or update the selected login user
  - Install the selected public key for that user
  - Enable passwordless sudo for that user
  - Regenerate machine ID, DHCP lease state, and SSH host keys for this clone
  - Change the VM hostname (.local suffix is published by mDNS)
  - Disable SSH password authentication for all users
  - Reboot the VM so .local/DHCP identity changes take effect
PLAN

if ! confirm "Proceed with SSH setup now?" "n"; then
  printf 'Cancelled. No remote commands were run.\n'
  exit 0
fi

tmp_dir="$(mktemp -d)"
remote_script="$tmp_dir/okrun-imported-vm-bootstrap.sh"
cleanup() {
  if [ -n "${remote_script:-}" ] && [ -f "$remote_script" ]; then
    rm -f "$remote_script"
  fi
  if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    rmdir "$tmp_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

create_remote_script "$remote_script"

printf '\nCopying setup script to %s...\n' "$target"
run_with_expect_password "$current_password" \
  scp \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  -P "$ssh_port" \
  "$remote_script" "${current_user}@${target}:/tmp/okrun-imported-vm-bootstrap.sh"

printf '\nRunning remote setup with expect password handling.\n'
run_with_expect_password "$current_password" \
  ssh \
  -tt \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  -p "$ssh_port" \
  "${current_user}@${target}" \
  "sudo bash /tmp/okrun-imported-vm-bootstrap.sh '$current_user' '$new_username' '$new_hostname' '$public_key_b64' '$lock_old_user'"

printf '\nSetup complete.\n'
