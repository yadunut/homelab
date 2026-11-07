"""Offline image pin regression check; no cluster access or container startup."""
import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "nousresearch/hermes-agent@sha256:e655ce57374faca9404db91c96893a05df18904e508cb98786d59a9c80ee8ecf"


class HermesImageTest(unittest.TestCase):
    def test_all_three_containers_use_verified_desktop_image(self):
        rendered = subprocess.check_output(
            [os.environ.get("KUBECTL", "kubectl"), "kustomize", "cluster/apps/hermes"],
            cwd=ROOT, text=True,
        )
        deployments = [resource for resource in yaml.safe_load_all(rendered)
                       if resource and resource.get("kind") == "Deployment"
                       and resource["metadata"]["name"] == "hermes"]
        self.assertEqual(len(deployments), 1)
        spec = deployments[0]["spec"]["template"]["spec"]
        containers = spec["initContainers"] + spec["containers"]
        # Networking sidecars have independent image pins.
        containers = [c for c in containers if c["name"] in
                      ("bootstrap", "computer-use-driver", "hermes")]
        self.assertEqual(len(containers), 3)
        self.assertEqual(
            {container["name"]: container["image"] for container in containers},
            {name: IMAGE for name in ("bootstrap", "computer-use-driver", "hermes")},
        )


if __name__ == "__main__":
    unittest.main()
