{ pkgs, lib, config, ... }:
let
  flannel = builtins.toJSON {
    name = "cbr0";
    cniVersion = "0.3.1";
    plugins = [
      {
        type = "flannel";
        delegate = {
          hairpinMode = true;
          forceAddress = true;
          isDefaultGateway = true;
        };
      }
      {
        type = "portmap";
        capabilities = {
          portMappings = true;
        };
      }
    ];
  };
in
{
  config = {
    environment.systemPackages = [
      (pkgs.runCommand "wrap-kubectl"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        } ''
        mkdir -p $out/bin
        makeWrapper ${pkgs.kubernetes}/bin/kubectl $out/bin/kubectl \
          --set KUBECONFIG "/etc/kubernetes/cluster-admin.kubeconfig"
      '')
      # having iptables in path is still useful for debugging
      pkgs.iptables
    ];

    services.k3s.enable = true;
    services.k3s.docker = false;

    # example firewall:
    networking.firewall.enable = true;
    networking.firewall.allowedTCPPortRanges = [ { from = 0; to = 65535; } ];
    networking.firewall.allowedUDPPortRanges = [ { from = 0; to = 65535; } ];
    networking.firewall.checkReversePath = false;
    # # keep in mind that the following may be ineffective, because kubernetes
    # # throws iptable rules all over the place at the wrong time
    # networking.firewall.extraCommands = ''
    #   iptables -I INPUT 1 -i tinc.retiolum -j DROP
    # '';
    # networking.firewall.extraStopCommands = ''
    #   iptables -D INPUT -i tinc.retiolum -j DROP
    # '';

    virtualisation.containerd.enable = true;

    virtualisation.containerd.settings = {
      plugins.cri.cni.conf_dir = "${pkgs.writeTextDir "net.d/10-flannel.conflist" flannel}/net.d";
    };

    systemd.services.containerd.serviceConfig = lib.mkIf config.boot.zfs.enabled {
      ExecStartPre = "-${pkgs.zfs}/bin/zfs create -o mountpoint=/var/lib/containerd/io.containerd.snapshotter.v1.zfs zroot/containerd";
    };

    systemd.services.k3s = {
      after = [ "vhive.service" ];
      wants = [ "vhive.service" ];
    };

    services.k3s.role = "server";
    services.k3s.extraFlags = toString [
      "--disable traefik"
      "--disable servicelb"
      "--flannel-backend=host-gw"
      "--container-runtime-endpoint unix:///etc/firecracker-containerd/fccd-cri.sock"
    ];
  };
}
