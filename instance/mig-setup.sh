#!/usr/bin/env bash
# mig-setup.sh - Create / remove MIG layouts on NVIDIA H200 and RTX PRO 6000
#
# Usage:
#   sudo ./mig-setup.sh            # GPU 0
#   sudo ./mig-setup.sh -i 1       # GPU 1
#   sudo ./mig-setup.sh -i 0,1,2   # several GPUs (same model)
#   sudo ./mig-setup.sh -i all     # every GPU in the box
#   -y   skip confirmations
#   -b   boot mode: re-apply the layout saved in /etc/mig-setup.conf
#        (used by mig-setup.service, not meant to be run by hand)

set -euo pipefail

CONF_FILE=/etc/mig-setup.conf
SERVICE_NAME=mig-setup.service
UNIT_FILE=/etc/systemd/system/$SERVICE_NAME
INSTALL_PATH=/usr/local/sbin/mig-setup.sh

GPU_ARG="0"
ASSUME_YES=0
BOOT_MODE=0
FAILED=()
RESET_NEEDED=()

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

die()  { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[36m[INFO]\e[0m  $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m  $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m    $*"; }

# Operational confirmation: -y answers yes
confirm() {
  (( ASSUME_YES )) && return 0
  local a
  read -rp "$1 [y/N] " a
  [[ $a =~ ^[Yy]$ ]]
}

while getopts ":i:ybh" opt; do
  case $opt in
    i) GPU_ARG="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    b) BOOT_MODE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
command -v nvidia-smi >/dev/null || die "nvidia-smi not found."

# ======================================================================
# GPU / layout helpers
# ======================================================================
detect_model() {
  local name
  name=$(nvidia-smi -i "$1" --query-gpu=name --format=csv,noheader 2>/dev/null) || return 1
  case "$name" in
    *H200*)       echo "H200" ;;
    *"PRO 6000"*) echo "PRO6000" ;;
    *)            echo "UNKNOWN:$name" ;;
  esac
}

layout_for() {   # model n
  case "$1:$2" in
    H200:2)    echo "3g.71gb,3g.71gb" ;;
    H200:4)    echo "1g.35gb,1g.35gb,1g.35gb,1g.35gb" ;;
    PRO6000:2) echo "2g.48gb,2g.48gb" ;;
    PRO6000:4) echo "1g.24gb,1g.24gb,1g.24gb,1g.24gb" ;;
    *) return 1 ;;
  esac
}

describe_for() { # model n
  case "$1:$2" in
    H200:2)    echo "2 x 3g.71gb  (~70 GB, 60 SMs each)" ;;
    H200:4)    echo "4 x 1g.35gb  (~32 GB, 26 SMs each)" ;;
    PRO6000:2) echo "2 x 2g.48gb  (~47 GB, 94 SMs each)" ;;
    PRO6000:4) echo "4 x 1g.24gb  (~23 GB, 46 SMs each)" ;;
  esac
}

ensure_persistence() {
  local pm
  pm=$(nvidia-smi -i "$1" --query-gpu=persistence_mode --format=csv,noheader | tr -d ' ')
  if [[ $pm != Enabled ]]; then
    info "GPU $1: enabling persistence mode"
    nvidia-smi -i "$1" -pm 1 >/dev/null
  fi
}

mig_state() {
  nvidia-smi -i "$1" --query-gpu=mig.mode.current,mig.mode.pending \
    --format=csv,noheader | tr -d ' ' | tr ',' ' '
}

# MIG devices of one GPU, as listed by `nvidia-smi -L`
list_mig_devices() {
  nvidia-smi -L 2>/dev/null | awk -v g="$1" '
    /^GPU [0-9]+:/ { cur = ($2 == g ":"); next }
    cur && /^[[:space:]]+MIG / { sub(/^[[:space:]]+/, ""); print }'
}

has_instances() {
  # MIG devices visible in nvidia-smi -L ...
  [[ -n $(list_mig_devices "$1") ]] && return 0
  # ... or GPU instances without a compute instance (not shown by -L)
  nvidia-smi mig -i "$1" -lgi 2>/dev/null | grep -qE 'MIG [0-9]+g\.'
}

show_existing() {
  local g=$1 devs
  devs=$(list_mig_devices "$g")
  if [[ -n $devs ]]; then
    sed 's/^/          /' <<< "$devs"
  else
    echo "          (GPU instances without compute instances)"
    nvidia-smi mig -i "$g" -lgi 2>/dev/null | grep -E 'MIG [0-9]+g\.' | sed 's/^/          /' || true
  fi
}

check_running_procs() {
  local g=$1 procs
  procs=$(nvidia-smi -i "$g" --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null \
          | grep -v '^No running' || true)
  if [[ -n $procs ]]; then
    warn "GPU $g has running compute processes:"
    sed 's/^/          /' <<< "$procs"
    confirm "Continue anyway (the operation will probably fail)?" || return 1
  fi
}

destroy_instances() {
  local g=$1
  check_running_procs "$g" || return 1
  info "GPU $g: destroying compute instances"
  nvidia-smi mig -i "$g" -dci >/dev/null 2>&1 || true
  info "GPU $g: destroying GPU instances"
  if ! nvidia-smi mig -i "$g" -dgi >/dev/null 2>&1; then
    warn "GPU $g: could not destroy GPU instances (still in use?)"
    return 1
  fi
}

ensure_mig() {
  local g=$1 cur pend
  read -r cur pend < <(mig_state "$g")
  if [[ $cur == Enabled ]]; then return 0; fi
  if [[ $cur == "[N/A]" ]]; then warn "GPU $g: MIG not supported."; return 1; fi

  if [[ $pend != Enabled ]]; then
    info "GPU $g: enabling MIG mode"
    nvidia-smi -i "$g" -mig 1 >/dev/null
    read -r cur pend < <(mig_state "$g")
  fi

  if [[ $cur != Enabled ]]; then
    warn "GPU $g: MIG enable is pending. Stop processes using the GPU, then run"
    warn "        'nvidia-smi -i $g -r' or reboot, and re-run this script."
    return 1
  fi
}

check_profiles() {  # gpu layout
  local g=$1 layout=$2 lgip p
  lgip=$(nvidia-smi mig -i "$g" -lgip)
  for p in $(tr ',' '\n' <<< "$layout" | sort -u); do
    if ! grep -qF "MIG $p " <<< "$lgip"; then
      warn "GPU $g: profile $p not available"
      return 1
    fi
  done
}

apply_gpu() {  # gpu n
  local g=$1 n=$2 model layout
  model=$(detect_model "$g") || { warn "GPU $g not found."; return 1; }
  if ! layout=$(layout_for "$model" "$n"); then
    warn "GPU $g: no ${n}xMIG layout for model '$model'"
    return 1
  fi

  info "===== GPU $g ($model, ${n}xMIG) ====="
  ensure_mig "$g" || return 1

  if has_instances "$g"; then
    warn "GPU $g already has MIG devices:"
    show_existing "$g"
    confirm "Destroy existing instances on GPU $g?" || { warn "GPU $g skipped."; return 1; }
    destroy_instances "$g" || return 1
  fi

  check_profiles "$g" "$layout" || return 1

  info "GPU $g: creating $layout"
  if nvidia-smi mig -i "$g" -cgi "$layout" -C; then
    ok "GPU $g done."
  else
    warn "GPU $g: creation failed."
    return 1
  fi
}

rollback_gpu() {
  local g=$1 cur pend
  info "===== GPU $g: rollback ====="
  read -r cur pend < <(mig_state "$g")

  if [[ $cur == "[N/A]" ]]; then
    warn "GPU $g: MIG not supported, nothing to do."
    return 0
  fi
  if [[ $cur == Disabled && $pend == Disabled ]]; then
    ok "GPU $g: MIG already disabled."
    return 0
  fi

  if [[ $cur == Enabled ]] && has_instances "$g"; then
    destroy_instances "$g" || return 1
  fi

  info "GPU $g: disabling MIG mode"
  if ! nvidia-smi -i "$g" -mig 0 >/dev/null; then
    warn "GPU $g: failed to disable MIG mode."
    return 1
  fi

  read -r cur pend < <(mig_state "$g")
  if [[ $cur == Enabled ]]; then
    warn "GPU $g: MIG disable is pending (needs GPU reset or reboot)."
    RESET_NEEDED+=("$g")
  else
    ok "GPU $g: MIG disabled."
  fi
}

# ======================================================================
# Boot-persistence helpers  (config format: SAVED_LAYOUT="0:2 1:4")
# ======================================================================
gpu_in_list() {
  local x=$1 y; shift
  for y in "$@"; do [[ $x == "$y" ]] && return 0; done
  return 1
}

load_saved() {
  if [[ -f $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    ( source "$CONF_FILE"; echo "${SAVED_LAYOUT:-}" )
  fi
}

# print saved entries, minus the given GPUs (normalised spacing)
filter_saved() {
  local saved=$1 e out=(); shift
  for e in $saved; do
    gpu_in_list "${e%%:*}" "$@" || out+=("$e")
  done
  echo "${out[*]:-}"
}

write_conf() {
  cat > "$CONF_FILE" <<EOF
# Generated by mig-setup.sh on $(date -Is)
# Format: <gpu_index>:<number_of_MIG_slices>
SAVED_LAYOUT="$1"
EOF
}

install_boot_service() {  # "gpu:n gpu:n ..."
  local new_entries=$1 saved merged src e gpus=()
  command -v systemctl >/dev/null || { warn "systemctl not found; boot service not installed."; return 1; }

  src=$(readlink -f "$0")
  if [[ $src != "$INSTALL_PATH" ]]; then
    install -m 0755 "$src" "$INSTALL_PATH"
  fi

  for e in $new_entries; do gpus+=("${e%%:*}"); done
  saved=$(load_saved)
  merged=$(filter_saved "$saved" "${gpus[@]}")
  # shellcheck disable=SC2086
  merged=$(echo $merged $new_entries)
  write_conf "$merged"

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Recreate NVIDIA MIG layout (mig-setup.sh)
After=nvidia-persistenced.service systemd-modules-load.service
Wants=nvidia-persistenced.service
Before=docker.service containerd.service kubelet.service nvidia-dcgm.service

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH -b
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  ok "Boot service enabled: $SERVICE_NAME"
  info "Saved boot layout ($CONF_FILE): $merged"
}

remove_boot_service() {
  if command -v systemctl >/dev/null; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_FILE" "$CONF_FILE" "$INSTALL_PATH"
  if command -v systemctl >/dev/null; then systemctl daemon-reload; fi
  ok "Boot service $SERVICE_NAME removed."
}

# Remove GPUs from the saved boot layout; remove the service if nothing is left
drop_from_boot() {
  local saved remaining
  saved=$(load_saved)
  [[ -n $saved || -f $UNIT_FILE ]] || return 0
  remaining=$(filter_saved "$saved" "$@")
  if [[ -z $remaining ]]; then
    remove_boot_service
  elif [[ $remaining != "$(filter_saved "$saved")" ]]; then
    write_conf "$remaining"
    info "Boot layout updated, remaining: $remaining"
  fi
}

# ======================================================================
# Boot mode (called by systemd)
# ======================================================================
if (( BOOT_MODE )); then
  ASSUME_YES=1
  saved=$(load_saved)
  [[ -n $saved ]] || die "No saved layout in $CONF_FILE"
  rc=0
  for e in $saved; do
    g=${e%%:*}; n=${e##*:}
    nvidia-smi -i "$g" -pm 1 >/dev/null 2>&1 || warn "GPU $g: could not enable persistence mode"
    apply_gpu "$g" "$n" || rc=1
  done
  nvidia-smi -L || true
  exit "$rc"
fi

# ======================================================================
# Interactive mode
# ======================================================================
if [[ $GPU_ARG == all ]]; then
  mapfile -t GPUS < <(nvidia-smi --query-gpu=index --format=csv,noheader | tr -d ' ')
else
  IFS=',' read -ra GPUS <<< "$GPU_ARG"
fi
(( ${#GPUS[@]} > 0 )) || die "No GPUs selected."

MODEL=$(detect_model "${GPUS[0]}") || die "GPU ${GPUS[0]} not found."
[[ $MODEL == UNKNOWN:* ]] && die "Unsupported GPU: ${MODEL#UNKNOWN:}"
for g in "${GPUS[@]}"; do
  m=$(detect_model "$g") || die "GPU $g not found."
  [[ $m == "$MODEL" ]] || die "GPU $g is $m, but GPU ${GPUS[0]} is $MODEL. Run separately per model."
done

info "Detected model : $MODEL"
info "Target GPU(s)  : ${GPUS[*]}"
echo
info "Checking existing MIG devices (nvidia-smi -L):"
for g in "${GPUS[@]}"; do
  if has_instances "$g"; then
    warn "GPU $g: MIG devices found"
    show_existing "$g"
  else
    info "GPU $g: no MIG devices"
  fi
done

saved_now=$(load_saved)
[[ -n $saved_now ]] && info "Saved boot layout: $saved_now"

echo
echo "Select action for $MODEL:"
echo "  1) 2xMIG -> $(describe_for "$MODEL" 2)"
echo "  2) 4xMIG -> $(describe_for "$MODEL" 4)"
echo "  3) Remove MIG (rollback)"
echo "  4) Quit"
while true; do
  read -rp "Choice [1-4]: " choice
  case $choice in
    1) ACTION=create; N=2; break ;;
    2) ACTION=create; N=4; break ;;
    3) ACTION=rollback; break ;;
    4) info "Bye."; exit 0 ;;
    *) warn "Invalid choice." ;;
  esac
done

# ---------------------------------------------------------------- create
if [[ $ACTION == create ]]; then
  echo
  echo "Plan:"
  for g in "${GPUS[@]}"; do
    echo "  GPU $g -> $(describe_for "$MODEL" "$N")"
  done

  echo "  + persistence mode on, layout recreated at every boot ($SERVICE_NAME)"

  echo
  confirm "Proceed?" || { info "Aborted."; exit 0; }

  DONE=()
  for g in "${GPUS[@]}"; do
    echo
    ensure_persistence "$g"
    if apply_gpu "$g" "$N"; then DONE+=("$g"); else FAILED+=("$g"); fi
  done

  if (( ${#DONE[@]} )); then
    echo
    entries=""
    for g in "${DONE[@]}"; do entries+="$g:$N "; done
    install_boot_service "$entries" || true
  fi

  echo
  info "MIG devices:"
  nvidia-smi -L || true
  echo
  if (( ${#FAILED[@]} )); then
    warn "Failed / skipped GPU(s): ${FAILED[*]}"
    exit 1
  fi
  ok "All done. Persistence mode is on; layout will be recreated at boot by $SERVICE_NAME."
  exit 0
fi

# -------------------------------------------------------------- rollback
echo
info "Current devices:"
nvidia-smi -L || true
echo
warn "Rollback will destroy ALL MIG instances, disable MIG mode and persistence mode on GPU(s): ${GPUS[*]}"
warn "Any saved boot layout for these GPU(s) will also be removed."
confirm "Proceed with rollback?" || { info "Aborted."; exit 0; }

for g in "${GPUS[@]}"; do
  echo
  rollback_gpu "$g" || FAILED+=("$g")
  if nvidia-smi -i "$g" -pm 0 >/dev/null; then
    info "GPU $g: persistence mode disabled"
  else
    warn "GPU $g: could not disable persistence mode"
  fi
done

echo
drop_from_boot "${GPUS[@]}"

echo
info "Devices after rollback:"
nvidia-smi -L || true
echo
if (( ${#RESET_NEEDED[@]} )); then
  warn "GPU(s) ${RESET_NEEDED[*]} need 'nvidia-smi -i <id> -r' or a reboot to finish disabling MIG."
fi
if (( ${#FAILED[@]} )); then
  warn "Rollback failed on GPU(s): ${FAILED[*]}"
  exit 1
fi
ok "Rollback complete."