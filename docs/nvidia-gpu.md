# NVIDIA GPU Pods

This cluster exposes NVIDIA GPUs to Kubernetes pods via
[CDI](https://github.com/cncf-tags/container-device-interface) and the
[nvidia-device-plugin](https://github.com/NVIDIA/k8s-device-plugin).

## How it works

1. **NixOS** (`nix/modules/kubernetes/09-nvidia-gpu.nix`) configures:
   - CDI spec generation at boot (`hardware.nvidia-container-toolkit`)
   - `nvidia-container-runtime` in CDI mode (`config.toml`)
   - An `nvidia` runtime handler in containerd
2. **Kubernetes** (`cluster/infrastructure/nvidia-device-plugin/`) deploys:
   - A `RuntimeClass` named `nvidia` pointing to the containerd handler
   - The nvidia-device-plugin DaemonSet (via Helm), pinned to GPU nodes
   - Time-slicing with 4 shared replicas per physical GPU

The device plugin discovers GPUs via NVML and advertises the shared resource
`nvidia.com/gpu.shared` on the node.

## GPU nodes

| Node    | GPU                          | VRAM  |
| ------- | ---------------------------- | ----- |
| penguin | NVIDIA RTX 2000 Ada Gen. | 16 GB |

## Running a pod with a GPU

This cluster is configured for time-sliced GPU sharing. All services that need
GPU access should request `nvidia.com/gpu.shared` in resource limits and set
`runtimeClassName: nvidia`.

Use `nvidia.com/gpu.shared`, not `nvidia.com/gpu`, unless the device plugin is
explicitly reconfigured back to exclusive GPU allocation.

Example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  runtimeClassName: nvidia
  nodeSelector:
    kubernetes.io/hostname: penguin
  containers:
    - name: cuda
      image: nvidia/cuda:13.0.0-base-ubuntu24.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu.shared: "1"
  restartPolicy: Never
```

Or as a one-liner with `kubectl`:

```sh
kubectl run gpu-test \
  --image=nvidia/cuda:13.0.0-base-ubuntu24.04 \
  --restart=Never \
  --overrides='{
    "spec": {
      "runtimeClassName": "nvidia",
      "nodeSelector": {"kubernetes.io/hostname": "penguin"},
      "containers": [{
        "name": "gpu-test",
        "image": "nvidia/cuda:13.0.0-base-ubuntu24.04",
        "command": ["nvidia-smi"],
        "resources": {"limits": {"nvidia.com/gpu.shared": "1"}}
      }]
    }
  }'
```

Check results:

```sh
kubectl logs gpu-test
kubectl delete pod gpu-test
```

## Troubleshooting

**"Driver/library version mismatch"** -- The machine was rebuilt with a new
kernel or driver but hasn't been rebooted. The loaded kernel module version
must match the userspace libraries. Reboot the node.

**CDI spec is empty (0 bytes)** -- Usually caused by the driver mismatch
above. After rebooting, the CDI generator runs on boot and populates
`/var/run/cdi/nvidia-container-toolkit.json`. To re-run it manually:

```sh
ssh penguin.wireguard "sudo systemctl restart nvidia-container-toolkit-cdi-generator"
```

**nvidia.com/gpu.shared missing from node capacity** -- Check the device plugin pod:

```sh
kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin
```

**Node shows SchedulingDisabled** -- The node was cordoned (e.g. during a
rebuild). Uncordon it:

```sh
kubectl uncordon penguin
```
