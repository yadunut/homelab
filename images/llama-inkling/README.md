# Inkling CUDA server image

This packages the exact Unsloth llama.cpp binary benchmarked on Penguin:
`b12649-mix-c7059d6`, source commit
`189f431bf58f433d376d718c7788b1bf4467fa72`, CUDA 12 portable build.
The runtime base is NVIDIA CUDA 12.8.1 on Ubuntu 22.04, pinned by digest.
The Containerfile verifies the release archive before extracting it.

On a Linux amd64 builder with Podman, use a temporary build context:

```sh
mkdir -p /tmp/llama-inkling-build
cp images/llama-inkling/Containerfile /tmp/llama-inkling-build/
curl --fail --location --retry 4 \
  --output /tmp/llama-inkling-build/llama-runtime.tar.gz \
  https://github.com/unslothai/llama.cpp/releases/download/b12649-mix-c7059d6/app-b12649-mix-c7059d6-linux-x64-cuda12-portable.tar.gz
podman build -f /tmp/llama-inkling-build/Containerfile \
  -t harbor.yadunut.dev/library/llama-inkling:b12649-mix-c7059d6-cuda12-20261128 \
  /tmp/llama-inkling-build
podman push harbor.yadunut.dev/library/llama-inkling:b12649-mix-c7059d6-cuda12-20261128
```

Registry credentials belong in an authenticated credential store, never in this
repository or image. Pin the resulting registry manifest digest in the Deployment.
The image contains no model weights or credentials. The existing init container
downloads and verifies the model and drafter onto the model PVC.

Publish large CUDA images from a cloud-side builder near Harbor: the ingress
upload timeout can interrupt large layers across Penguin's WAN link. Harbor's
registry PVC is explicitly sized at 10 GiB to accommodate this runtime alongside
existing images; check free space before publishing another large version.
