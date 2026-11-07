"""Offline rendered-resource contract; not a live tunnel/DNS/ACL test."""
import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class HermesTailscaleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = list(yaml.safe_load_all(subprocess.check_output(
            [os.environ.get("KUBECTL", "kubectl"), "kustomize", "cluster/apps/hermes"],
            cwd=ROOT, text=True,
        )))
        cls.deployment = next(r for r in cls.resources if r["kind"] == "Deployment")
        cls.pod = cls.deployment["spec"]["template"]["spec"]

    def test_local_dns_starts_before_network_dependent_init(self):
        self.assertEqual(self.pod.get("dnsPolicy"), "None")
        self.assertEqual(self.pod["dnsConfig"], {
            "nameservers": ["::1"],
            "searches": ["hermes.svc.k8s.internal", "svc.k8s.internal", "k8s.internal"],
            "options": [{"name": "ndots", "value": "1"}],
        })
        dns = self.pod["initContainers"][0]
        self.assertEqual(dns["name"], "tailnet-dns")
        self.assertEqual(dns["restartPolicy"], "Always")
        self.assertIn("startupProbe", dns)
        self.assertIn("readinessProbe", dns)
        self.assertEqual(dns["image"], "coredns/coredns:1.15.0@sha256:0a9d8c8ddf34347eb59aad9a8784f0710de88d6d112726d11d271f9bc6daca26")
        corefile = next(r["data"]["Corefile"] for r in self.resources
                        if r["kind"] == "ConfigMap" and "Corefile" in r.get("data", {}))
        corefile = "\n".join(line for line in corefile.splitlines() if not line.lstrip().startswith("#"))
        self.assertIn("tail8dce03.ts.net:53", corefile)
        self.assertIn("forward . [fd7a:115c:a1e0::53]", corefile)
        self.assertIn("forward . [fd00:10:97::a]", corefile)
        self.assertEqual(corefile.count("bind ::1"), 2)
        for unsafe in ("/etc/resolv.conf", "dns64", "fallthrough", "100.100.100.100"):
            self.assertNotIn(unsafe, corefile)
        cluster = list(yaml.safe_load_all((ROOT / "cluster/infrastructure/coredns/coredns.yaml").read_text()))
        service = next(r for r in cluster if r["kind"] == "Service")
        self.assertIn("[" + service["spec"]["clusterIP"] + "]", corefile)

    def test_kernel_tunnel_is_isolated_and_persistent(self):
        ts = self.pod["initContainers"][1]
        self.assertEqual(ts["name"], "tailscale")
        self.assertEqual(ts["restartPolicy"], "Always")
        self.assertIn("startupProbe", ts)
        self.assertIn("readinessProbe", ts)
        self.assertEqual(ts["image"], "tailscale/tailscale:v1.104.4@sha256:ed6480b33c6eb67c9cbd203ed42b9fb57e361986725b6856def71b7a3d9e276c")
        env = {e["name"]: e for e in ts["env"]}
        for name, value in {
            "TS_USERSPACE": "false", "TS_ACCEPT_DNS": "false",
            "TS_KUBE_SECRET": "", "TS_AUTH_ONCE": "true",
            "TS_STATE_DIR": "/var/lib/tailscale", "TS_HOSTNAME": "hermes",
            "TS_DEBUG_FIREWALL_MODE": "nftables",
        }.items():
            self.assertEqual(env[name]["value"], value)
        self.assertEqual(env["TS_AUTHKEY"]["valueFrom"]["secretKeyRef"],
                         {"name": "hermes-tailscale", "key": "TS_AUTHKEY"})
        self.assertEqual(env["TS_EXTRA_ARGS"]["value"],
                         "--advertise-tags=tag:hermes --accept-routes=false --netfilter-mode=on --shields-up")
        security = ts["securityContext"]
        self.assertFalse(security.get("privileged", False))
        self.assertFalse(security["allowPrivilegeEscalation"])
        self.assertEqual(security["runAsUser"], 0)
        self.assertEqual(security["capabilities"], {"drop": ["ALL"], "add": ["NET_ADMIN"]})
        volumes = {v["name"]: v for v in self.pod["volumes"]}
        self.assertEqual(volumes["tailscale-state"]["persistentVolumeClaim"]["claimName"], "hermes-tailscale")
        self.assertEqual(volumes["tailscale-tun"]["hostPath"],
                         {"path": "/dev/net/tun", "type": "CharDevice"})
        mounts = {v["name"]: v["mountPath"] for v in ts["volumeMounts"]}
        self.assertEqual(mounts["tailscale-state"], "/var/lib/tailscale")
        self.assertEqual(mounts["tailscale-tun"], "/dev/net/tun")
        self.assertFalse(set(mounts) & {"data", "kubernetes-api", "kubeconfig"})
        for container in self.pod["initContainers"] + self.pod["containers"]:
            if container["name"] != "tailscale":
                self.assertFalse({m["name"] for m in container.get("volumeMounts", [])}
                                 & {"tailscale-state", "tailscale-tun", "tailscale-run"})
            self.assertFalse({e["name"].upper() for e in container.get("env", [])}
                             & {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "TS_SOCKS5_SERVER", "TS_OUTBOUND_HTTP_PROXY_LISTEN"})
        self.assertFalse(self.pod["automountServiceAccountToken"])
        self.assertFalse(self.pod.get("hostNetwork", False))
        self.assertEqual(self.deployment["spec"]["replicas"], 1)
        self.assertEqual(self.deployment["spec"]["strategy"]["type"], "Recreate")
        item = next(r for r in self.resources if r["kind"] == "OnePasswordItem"
                    and r["metadata"]["name"] == "hermes-tailscale")
        self.assertEqual(item["spec"]["itemPath"], "vaults/cluster/items/hermes-tailscale")
        pvc = next(r for r in self.resources if r["kind"] == "PersistentVolumeClaim"
                   and r["metadata"]["name"] == "hermes-tailscale")
        self.assertEqual(pvc["spec"]["accessModes"], ["ReadWriteOnce"])
        self.assertEqual(pvc["spec"]["storageClassName"], "longhorn")
        hermes = next(c for c in self.pod["containers"] if c["name"] == "hermes")
        self.assertEqual(next(e["value"] for e in hermes["env"] if e["name"] == "BB_SERVER_URL"),
                         "https://yadunut-grep-bb.tail8dce03.ts.net")


if __name__ == "__main__":
    unittest.main()
