{
  flake.modules.nixos.kubernetes-control-plane =
    { pkgs, config, ... }:
    let
      secrets = config.age.secrets;

      # RBAC manifests for cluster bootstrap
      rbacManifests = pkgs.writeText "rbac-manifests.yaml" ''
        ---
        # Allow API server to communicate with kubelets (for logs, exec, port-forward)
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: system:kube-apiserver-to-kubelet
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: system:kubelet-api-admin
        subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: User
          name: kube-apiserver-kubelet-client
        ---
        # Allow controller-manager to approve node client certificate CSRs
        # This enables kubelet client certificate rotation
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: system:controller-manager:approve-node-client-csrs
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
        subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: User
          name: system:kube-controller-manager
        ---
        # Allow controller-manager to approve node client certificate renewal CSRs
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: system:controller-manager:approve-node-client-renewal-csrs
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
        subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: User
          name: system:kube-controller-manager
        ---
        # Allow controller-manager to manage leases for leader election
        apiVersion: rbac.authorization.k8s.io/v1
        kind: RoleBinding
        metadata:
          name: system:controller-manager:lease-management
          namespace: kube-system
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: system:kube-controller-manager
        subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: User
          name: system:kube-controller-manager
      '';
    in
    {
      # Place RBAC manifests in a well-known location
      environment.etc."kubernetes/manifests/rbac.yaml".source = rbacManifests;

      # Systemd service to apply RBAC manifests after API server is healthy
      systemd.services."kubernetes-rbac-bootstrap" = {
        description = "Bootstrap Kubernetes RBAC";
        documentation = [ "https://kubernetes.io/docs/reference/access-authn-authz/rbac/" ];
        wantedBy = [ "kubernetes.target" ];
        after = [ "kube-apiserver.service" ];
        requires = [ "kube-apiserver.service" ];

        # Only run once, or when manifests change
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;

          ExecStart = pkgs.writeShellScript "kubernetes-rbac-bootstrap" ''
            set -euo pipefail

            export KUBECONFIG="${secrets.kubernetes-admin-kubeconfig.path}"

            echo "Waiting for API server to be ready..."
            timeout=120
            while ! ${pkgs.kubernetes}/bin/kubectl get --raw /healthz &>/dev/null; do
              timeout=$((timeout - 1))
              if [ $timeout -le 0 ]; then
                echo "Timeout waiting for API server"
                exit 1
              fi
              sleep 1
            done

            echo "API server is ready, applying RBAC manifests..."
            ${pkgs.kubernetes}/bin/kubectl apply -f /etc/kubernetes/manifests/rbac.yaml

            echo "RBAC bootstrap complete"
          '';
        };
      };
    };
}
