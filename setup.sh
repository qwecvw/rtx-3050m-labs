#!/bin/sh
# Install everything the GPU scripts need.
#   root part: CUDA toolkit (for gpu-burn), nvidia-powerd D-Bus policy (Dynamic Boost)
#   user part: gpu-burn built for the RTX 3050 (sm_86) and memtest_vulkan into tools/
# nvflash cannot be fetched by script (TechPowerUp captcha); see README.
# Run: sudo ./setup.sh
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
user=${SUDO_USER:?run via sudo from your user}
here=$(dirname "$(readlink -f "$0")")

apt-get install -y git wget unzip

if ! ls /usr/local/cuda/bin/nvcc >/dev/null 2>&1; then
  if ! ls /etc/apt/sources.list.d/cuda-*.list >/dev/null 2>&1; then
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
    dpkg -i /tmp/cuda-keyring.deb
    rm -f /tmp/cuda-keyring.deb
    apt-get update
  fi
  apt-get install -y cuda-toolkit-12-6
fi

# Dynamic Boost: nvidia-powerd needs its D-Bus policy, Ubuntu only ships it as documentation
conf=$(ls /usr/share/doc/nvidia-driver-*/nvidia-dbus.conf 2>/dev/null | tail -1)
if [ -n "$conf" ]; then
  install -m 644 "$conf" /etc/dbus-1/system.d/nvidia-dbus.conf
  systemctl reload dbus
  systemctl enable --now nvidia-powerd
  systemctl restart nvidia-powerd
fi

sudo -u "$user" sh -e <<EOF
mkdir -p "$here/tools" "$here/firmware" "$here/results"
cd "$here/tools"
[ -d gpu-burn ] || git clone -q https://github.com/wilicc/gpu-burn.git
cd gpu-burn && make clean >/dev/null 2>&1 || true
make COMPUTE=86
cd "$here/tools"
if [ ! -x memtest_vulkan/memtest_vulkan ]; then
  mkdir -p memtest_vulkan
  wget -qO- https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0_DesktopLinux_X86_64.tar.xz | tar xJ -C memtest_vulkan
fi
EOF

echo ""
echo "Ready: tools/gpu-burn, tools/memtest_vulkan. Dynamic Boost needs AC + platform profile 'performance'."
command -v nvflash >/dev/null && echo "nvflash: $(command -v nvflash)" || echo "nvflash: not installed (only needed for backup/flash)"
