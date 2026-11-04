# NVIDIA GPU support for Kubernetes compute nodes.
#
# Architecture overview:
#   1. NixOS module (hardware.nvidia-container-toolkit) generates a CDI spec at
#      /var/run/cdi/nvidia-container-toolkit.json on boot. This spec describes
#      available GPU devices, required /dev nodes, library mounts (from the nix
#      store), and OCI hooks (ldcache update, cuda-compat).
#   2. config.toml tells nvidia-container-runtime to operate in CDI mode. The
#      nvidia-container-runtime wraps runc and is invoked by containerd for pods
#      using runtimeClassName "nvidia".
#   3. Containerd is configured with enable_cdi=true and an "nvidia" runtime
#      handler pointing to nvidia-container-runtime.
#   4. On the Kubernetes side (see homelab repo), a RuntimeClass named "nvidia"
#      maps to the containerd handler, and the nvidia-device-plugin DaemonSet
#      discovers GPUs via NVML and advertises nvidia.com/gpu resources.
#
# Why we can't drop the nvidia runtime and rely solely on containerd's native
# CDI support: the nvidia-device-plugin requires NVML to discover GPUs. NVML is
# only available inside the container when nvidia-container-runtime injects the
# host's nvidia libraries. Without the runtime, the plugin fails at startup
# with "CDI --device-list-strategy options are only supported on NVML-based
# systems".
#
# After kernel or driver updates, the machine MUST be rebooted. The kernel
# module version must match the userspace library version; a mismatch causes
# nvidia-smi and CDI generation to fail with "Driver/library version mismatch".
# To regenerate CDI specs without rebooting (e.g. after a NixOS rebuild that
# didn't change the kernel): systemctl restart nvidia-container-toolkit-cdi-generator
{ ... }:
{
  flake.modules.nixos.kubernetes-compute =
    {
      lib,
      pkgs,
      config,
      ...
    }:
    let
      cfg = config.nut.kubernetes.nvidia;
    in
    {
      config = lib.mkIf cfg.enable {
        # CDI spec generation: creates /var/run/cdi/nvidia-container-toolkit.json
        # with device nodes, nix store library mounts, and OCI hooks.
        hardware.nvidia-container-toolkit.enable = true;
        hardware.nvidia-container-toolkit.device-name-strategy = "uuid";
        hardware.nvidia-container-toolkit.mount-nvidia-executables = true;

        # nvidia-container-runtime config. Must use mode = "cdi" so the runtime
        # reads device info from CDI specs rather than using the legacy
        # nvidia-container-runtime-hook injection. All paths are pinned to nix
        # store derivations so they stay consistent across rebuilds.
        environment.etc."nvidia-container-runtime/config.toml".text = ''
          disable-require = true
          supported-driver-capabilities = "compat32,compute,display,graphics,ngx,utility,video"
          [nvidia-container-cli]
          environment = []
          ldconfig = "@${lib.getExe' pkgs.glibc "ldconfig"}"
          load-kmods = true
          no-cgroups = false
          path = "${lib.getExe' pkgs.libnvidia-container "nvidia-container-cli"}"
          [nvidia-container-runtime]
          mode = "cdi"
          runtimes = ["${lib.getExe pkgs.runc}", "runc", "crun"]
          [nvidia-container-runtime-hook]
          path = "${lib.getOutput "tools" pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime-hook"
          skip-mode-detection = false
          [nvidia-ctk]
          path = "${lib.getExe' pkgs.nvidia-container-toolkit "nvidia-ctk"}"
        '';

        # Containerd: enable CDI support and register the nvidia runtime handler.
        # Pods with runtimeClassName "nvidia" use nvidia-container-runtime as
        # their OCI runtime, which injects GPU devices/libraries via CDI.
        virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri" = {
          enable_cdi = true;
          cdi_spec_dirs = [
            "/etc/cdi"
            "/var/run/cdi"
          ];
          containerd = {
            runtimes.nvidia = {
              privileged_without_host_devices = false;
              runtime_type = "io.containerd.runc.v2";
              options = {
                BinaryName =
                    "${lib.getOutput "tools" pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
              };
            };
          };
        };
      };
    };
}
