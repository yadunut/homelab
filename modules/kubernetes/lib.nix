{ lib, ... }:
let
  stripCidrBase =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      baseAddr = lib.head parts;
    in
    lib.removeSuffix "]" (lib.removePrefix "[" baseAddr);

  replaceCidrSuffix = { cidr, suffix }: lib.replaceStrings [ "::" ] [ suffix ] (stripCidrBase cidr);

  mkStepCertificate =
    {
      pkgs,
      caGenerator,
      name,
      commonName,
      orgs ? [ ],
      extKeyUsage ? [ "clientAuth" ],
      sans ? [ ],
      keyOwner ? "kubernetes",
      keyGroup ? "kubernetes",
      share ? false,
    }:
    {
      inherit share;
      file = "${name}.key";
      publicFiles = [ "${name}.crt" ];
      owner = keyOwner;
      group = keyGroup;
      mode = "0440";

      dependencies = [ caGenerator ];
      runtimeInputs = pkgs: [ pkgs.step-cli ];
      script = ''
        cat > ${name}.tpl <<EOF
        {
          "subject": {
            "commonName": "${commonName}"${
              if orgs != [ ] then ",\n              \"organization\": ${builtins.toJSON orgs}" else ""
            }
          },
          "keyUsage": ["digitalSignature", "keyEncipherment"],
          "basicConstraints": { "isCA": false },
          "extKeyUsage": ${builtins.toJSON extKeyUsage}${
            if sans != [ ] then ",\n          \"sans\": {{ toJson .SANs }}" else ""
          }
        }
        EOF

        step certificate create ${name} $out/${name}.crt $out/${name}.key \
          --template ${name}.tpl \
          --ca $in/${caGenerator}/ca.crt \
          --ca-key $in/${caGenerator}/ca.key \
          --no-password --insecure \
          --not-after 8760h \
          ${builtins.concatStringsSep " " (map (san: "--san ${san}") sans)}
      '';
    };
in
{
  _module.args.kubeLib = rec {
    firstServiceIP =
      cidr:
      replaceCidrSuffix {
        inherit cidr;
        suffix = "::1";
      };
    dnsIP =
      cidr:
      replaceCidrSuffix {
        inherit cidr;
        suffix = "::a";
      };

    mkTmpfileDir =
      {
        path,
        mode ? "0755",
        user ? "root",
        group ? "root",
      }:
      "d ${path} ${mode} ${user} ${group} -";

    mkTmpfileLink =
      {
        dest,
        src,
      }:
      "L+ ${dest} - - - - ${src}";

    mkTmpfileLinks = links: map mkTmpfileLink links;

    mkWaitForIP =
      {
        pkgs,
        nodeIP,
      }:
      let
        isIPv6 = lib.hasInfix ":" nodeIP;
        familyFlag = if isIPv6 then "-6" else "-4";
        inetLabel = if isIPv6 then "inet6" else "inet";
        exactAddressMatch = "${pkgs.iproute2}/bin/ip -o ${familyFlag} addr show | grep -Fq \"${inetLabel} ${nodeIP}/\"";
        tentativeMatch = "${pkgs.iproute2}/bin/ip -o -6 addr show tentative | grep -Fq \"inet6 ${nodeIP}/\"";
        dadFailedMatch = "${pkgs.iproute2}/bin/ip -o -6 addr show dadfailed | grep -Fq \"inet6 ${nodeIP}/\"";
      in
      pkgs.writeShellScript "wait-for-ip" ''
        set -euo pipefail
        ${
          if isIPv6 then
            ''
              while true; do
                if ${exactAddressMatch} && ! ${tentativeMatch} && ! ${dadFailedMatch}; then
                  exit 0
                fi
                sleep 1
              done
            ''
          else
            ''
              while ! ${exactAddressMatch}; do
                sleep 1
              done
            ''
        }
      '';

    mkKubeconfig =
      {
        pkgs,
        name,
        clusterName,
        server,
        user,
        certGenerator,
        certFile,
        keyFile,
        share ? false,
        owner ? "kubernetes",
        group ? "kubernetes",
        mode ? "0440",
      }:
      {
        inherit share;
        file = "${name}.kubeconfig";
        inherit owner group mode;
        dependencies = [
          "kubernetes-ca-crt"
          certGenerator
        ];
        runtimeInputs = pkgs: [ pkgs.kubectl ];
        script = ''
          kubectl config set-cluster ${clusterName} \
            --certificate-authority=$in/kubernetes-ca-crt/ca.crt \
            --embed-certs=true \
            --server=${server} \
            --kubeconfig=$out/${name}.kubeconfig

          kubectl config set-credentials ${user} \
            --client-certificate=$in/${certGenerator}/${certFile} \
            --client-key=$in/${certGenerator}/${keyFile} \
            --embed-certs=true \
            --kubeconfig=$out/${name}.kubeconfig

          kubectl config set-context default \
            --cluster=${clusterName} \
            --user=${user} \
            --kubeconfig=$out/${name}.kubeconfig

          kubectl config use-context default \
            --kubeconfig=$out/${name}.kubeconfig
        '';
      };

    mkK8sCertificate = args: mkStepCertificate ({ caGenerator = "kubernetes-ca-crt"; } // args);
    mkEtcdCertificate =
      args:
      mkStepCertificate (
        {
          caGenerator = "etcd-ca-crt";
          keyOwner = "etcd";
          keyGroup = "etcd";
        }
        // args
      );
  };
}
