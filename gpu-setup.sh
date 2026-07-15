#!/usr/bin/env bash
#
# gpu-setup.sh -- detect this host's GPU and report what's needed to run Ollama on it.
#
# GPU drivers CANNOT be baked into the Ollama image: a GPU's kernel driver (nvidia.ko, amdgpu,
# i915) lives on the HOST; the container only carries the userspace runtime (CUDA/ROCm/oneAPI).
# So on a fresh server you install the vendor stack HERE, once, then bring Ollama up with the
# matching compose profile. This script detects the GPU, checks what's already in place, and
# prints the exact host steps + the `--profile` to use. It changes nothing by default.
#
#   ./gpu-setup.sh                      # detect + report (read-only)
#   ./gpu-setup.sh --install-nvidia-ct  # ALSO install the NVIDIA Container Toolkit (Debian/Ubuntu)
#
# The kernel drivers themselves (NVIDIA proprietary, AMD ROCm, Intel compute-runtime) are
# distro- and version-specific and are NOT auto-installed here -- the script points you at the
# right packages so you can install them deliberately.
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
info() { printf '      %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

INSTALL_NVIDIA_CT=0
for arg in "$@"; do
  case "$arg" in
    --install-nvidia-ct) INSTALL_NVIDIA_CT=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# --- detect GPUs on the PCI bus ---------------------------------------------------------------
log "detecting GPUs"
gpu_lines=""
if have lspci; then
  gpu_lines="$(lspci 2>/dev/null | grep -iE 'vga compatible controller|3d controller|display controller' || true)"
fi
if [[ -n "$gpu_lines" ]]; then
  while IFS= read -r line; do info "$line"; done <<<"$gpu_lines"
else
  warn "no GPU found on the PCI bus (or lspci missing). CPU inference still works: --profile ai-cpu"
fi

has_vendor() { grep -qiE "$1" <<<"$gpu_lines"; }
NVIDIA=0; AMD=0; INTEL=0
has_vendor 'nvidia'            && NVIDIA=1
has_vendor 'amd|ati|advanced micro' && AMD=1
has_vendor 'intel'            && INTEL=1

# --- report render nodes + docker plumbing ----------------------------------------------------
log "host capabilities"
if [[ -e /dev/dri ]]; then
  ok "/dev/dri present: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
else
  warn "/dev/dri missing -- no render nodes (needed for AMD ROCm and Intel)"
fi
[[ -e /dev/kfd ]] && ok "/dev/kfd present (AMD compute node)" || info "/dev/kfd absent (AMD ROCm not active)"
if have docker && docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia|nvidia'; then
  ok "docker sees the NVIDIA runtime"
else
  info "docker has no NVIDIA runtime configured yet"
fi

# --- per-vendor guidance ----------------------------------------------------------------------
recommend() { printf '\n\033[1;32mRecommended profile:\033[0m docker compose --profile %s up -d\n' "$1"; }

if [[ "$NVIDIA" == 1 ]]; then
  log "NVIDIA GPU -> profile ai-nvidia"
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    ok "NVIDIA kernel driver is up:"; nvidia-smi -L | while IFS= read -r l; do info "$l"; done
  else
    warn "NVIDIA kernel driver NOT active. Install it first (Debian/Ubuntu):"
    info "sudo apt-get install -y nvidia-driver firmware-misc-nonfree   # then reboot"
    info "(or the vendor .run / CUDA repo for your distro; verify with: nvidia-smi)"
  fi
  # The NVIDIA Container Toolkit is the safely-automatable piece; offer to install it.
  if have nvidia-ctk; then
    ok "NVIDIA Container Toolkit already installed"
  elif [[ "$INSTALL_NVIDIA_CT" == 1 ]]; then
    [[ $EUID -eq 0 ]] || die "run with sudo to install the toolkit: sudo ./gpu-setup.sh --install-nvidia-ct"
    have apt-get || die "auto-install supports Debian/Ubuntu (apt) only; see NVIDIA's docs for your distro"
    log "installing the NVIDIA Container Toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update && apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
    ok "toolkit installed + docker configured"
  else
    warn "NVIDIA Container Toolkit missing (lets containers see the GPU). Install it with:"
    info "sudo ./gpu-setup.sh --install-nvidia-ct        # Debian/Ubuntu, automated"
    info "or follow https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/ for your distro"
  fi
  recommend ai-nvidia
fi

if [[ "$AMD" == 1 ]]; then
  log "AMD GPU -> profile ai-amd"
  if have rocminfo && rocminfo >/dev/null 2>&1; then
    ok "ROCm stack responds (rocminfo ok)"
  else
    warn "AMD compute stack not confirmed. On the host:"
    info "install amdgpu + ROCm for your card+distro: https://rocm.docs.amd.com/projects/install-on-linux/"
    info "ensure /dev/kfd and /dev/dri exist, and add yourself: sudo usermod -aG render,video \$USER"
  fi
  info "the ai-amd profile passes /dev/kfd + /dev/dri through and joins groups render,video."
  info "unsupported consumer card? set HSA_OVERRIDE_GFX_VERSION in compose/ollama.yaml (see comments)."
  recommend ai-amd
fi

if [[ "$INTEL" == 1 ]]; then
  log "Intel GPU -> profile ai-intel (EXPERIMENTAL)"
  warn "mainline Ollama has no Intel GPU backend; the ai-intel profile uses Intel's IPEX-LLM build."
  if have clinfo && clinfo 2>/dev/null | grep -qi intel; then
    ok "Intel OpenCL/Level-Zero runtime detected"
  else
    info "install Intel's compute runtime + Level-Zero on the host:"
    info "https://dgpu-docs.intel.com/driver/installation.html  (ensure /dev/dri render nodes exist)"
  fi
  info "set DEVICE=iGPU (integrated) or DEVICE=Arc (discrete) in compose/ollama.yaml."
  recommend ai-intel
fi

if [[ "$NVIDIA$AMD$INTEL" == "000" ]]; then
  log "no discrete/integrated GPU matched -> CPU"
  info "CPU inference needs no drivers and works today."
  recommend ai-cpu
fi

printf '\nAfter starting a profile, verify: ./test.sh   (Ollama + Open WebUI section)\n'
