{
  config,
  kubeLib,
  ...
}:
{
  flake.modules.nixos.kubernetes-control-plane =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      secrets = config.age.secrets;
      hostname = config.networking.hostName;
      nodeIp = config.nut.kubernetes.nodeIP;
      controlPlane = config.nut.kubernetes.controlPlane;
      initialClusterMember = "${controlPlane.name}=https://[${controlPlane.ip}]:2380";
      etcdEndpoint = "https://[${controlPlane.ip}]:2379";
    in
    {
      services.etcd = {
        enable = true;
        name = hostname;

        # Listen addresses (using the stable core network loopback).
        listenClientUrls = [
          "https://[${nodeIp}]:2379"
          "https://[::1]:2379"
        ];
        advertiseClientUrls = [ "https://[${nodeIp}]:2379" ];

        listenPeerUrls = [ "https://[${nodeIp}]:2380" ];
        initialAdvertisePeerUrls = [ "https://[${nodeIp}]:2380" ];

        # Cluster configuration
        initialCluster = [ initialClusterMember ];
        initialClusterState = "new";
        initialClusterToken = "kubernetes-etcd-cluster";

        # TLS configuration for client connections
        clientCertAuth = true;
        trustedCaFile = secrets.etcd-ca-crt.settings.publicFiles."ca.crt";
        certFile = secrets.etcd-server-crt.settings.publicFiles."etcd-server.crt";
        keyFile = secrets.etcd-server-crt.path;

        # TLS configuration for peer connections
        peerClientCertAuth = true;
        peerTrustedCaFile = secrets.etcd-ca-crt.settings.publicFiles."ca.crt";
        peerCertFile = secrets.etcd-peer-crt.settings.publicFiles."etcd-peer.crt";
        peerKeyFile = secrets.etcd-peer-crt.path;

        # Data directory
        dataDir = "/var/lib/etcd";
      };

      systemd.services.etcd = {
        after = [ "kubernetes-core-network-ready.service" ];
        wants = [ "kubernetes-core-network-ready.service" ];
        requires = [ "kubernetes-core-network-ready.service" ];
        serviceConfig.ExecStartPre = [
          # Wait for the node IP to be available on some interface
          (kubeLib.mkWaitForIP {
            inherit pkgs;
            nodeIP = nodeIp;
          })
        ];
      };

      # Export etcdEndpoints for other modules (like kube-apiserver) to use
      nut.kubernetes.etcd = {
        endpoints = etcdEndpoint;
        initialCluster = initialClusterMember;
      };
    };
}
