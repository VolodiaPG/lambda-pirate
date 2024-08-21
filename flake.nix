{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-21.11";
    nixpkgs2.url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs2,
    flake-utils,
    fenix,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux"]
    (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs2 = nixpkgs2.legacyPackages.${system};
      fenixPkgs = fenix.packages.${system};
      rustToolchain = with fenixPkgs;
        combine [
          stable.cargo
          stable.rustc
          stable.rust-std
          targets.x86_64-unknown-linux-musl.stable.rust-std
        ];
      rustPlatform = pkgs.makeRustPlatform {
        cargo = rustToolchain;
        rustc = rustToolchain;
      };
      ownPkgs = self.packages.${pkgs.system};
      deployPkgs = [
        pkgs.kubectl
        pkgs.coreutils
        pkgs.nettools
        pkgs.envsubst
        pkgs.openssl
        pkgs.gnused
        pkgs.curl
        pkgs.istioctl
        pkgs.curl
        pkgs.go
        pkgs.go-langserver
        pkgs.delve
        pkgs.lsof
      ];
      packageOverrides = pkgs.callPackage ./nix/python-packages.nix {};
      python = pkgs.python3.override {inherit packageOverrides;};
      pythonWithPackages = python.withPackages (ps: [ps.logfmt]);
    in {
      packages = rec {
        firecracker = pkgs.callPackage ./nix/pkgs/firecracker.nix {
          inherit rustPlatform;
        };
        firecracker-kernel = pkgs.callPackage ./nix/pkgs/firecracker-kernel.nix {
          inherit firecracker;
        };
        firecracker-containerd = pkgs.callPackage ./nix/pkgs/firecracker-containerd {};
        firecracker-ctr = pkgs.callPackage ./nix/pkgs/firecracker-ctr.nix {};
        firecracker-rootfs = pkgs2.callPackage ./nix/pkgs/firecracker-rootfs {
          inherit firecracker-containerd runc-static;
        };
        runc-static = pkgs.callPackage ./nix/pkgs/runc-static.nix {};
        vhive = pkgs.callPackage ./nix/pkgs/vhive.nix {inherit pkgs;};
        kn = pkgs.callPackage ./nix/pkgs/kn.nix {};
        vhive-examples = pkgs.callPackage ./nix/pkgs/vhive-examples.nix {
          inherit vhive kn;
        };
        deploy-knative = pkgs.writeShellScriptBin "deploy-knative" ''
          export PATH=${pkgs.lib.makeBinPath deployPkgs}
          # too expensive. Maybe we should remove deploy-knative entirely.
          # exec ${pkgs.gnumake}/bin/make -C ${./knative} deploy
        '';
      };
      apps.microvm = {
        type = "app";
        program = "${self.nixosConfigurations.microvm.config.microvm.declaredRunner}/bin/microvm-run";
      };
      devShell = pkgs.mkShell {
        buildInputs =
          deployPkgs
          ++ [
            pkgs.just
            pkgs.jq
            pkgs.libcgroup
            pkgs.skopeo
            pkgs.just
            pkgs.istioctl
            ownPkgs.kn
            #      ownPkgs.vhive-examples
            pythonWithPackages
          ];
        shellHook = ''
          if [ -n $KUBECONFIG ]; then
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
          fi
        '';
      };
    })
    // {
      nixosConfigurations = {
        example-host = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.knative
            self.nixosModules.vhive
            #{boot.isContainer = true;}
            ({lib, ...}: {
              services.vhive.dockerRegistryIp = "127.0.0.1";

              boot.loader.grub.device = "/dev/sda"; # Install GRUB to the disk

              # Networking setup
              networking.hostName = "nixos"; # Set your VM hostname
              networking.useDHCP = true; # Enable DHCP for network configuration

              # User configuration
              services.getty.autologinUser = "nixos";
              users.users.nixos = {
                isNormalUser = true;
                home = "/home/nixos";
                initialPassword = "nixos"; # Replace with your own password
                extraGroups = ["wheel" "networkmanager"]; # Add the user to important groups
              };

              # Enable sudo without password for wheel group (optional, but useful for initial setup)
              security.sudo.wheelNeedsPassword = false;

              # Enable and configure SSH service
              services.openssh.enable = true;
              services.openssh.permitRootLogin = "yes"; # Allow root login (optional, set to "no" for more security)
              services.openssh.passwordAuthentication = true; # Allow password authentication

              # Enable a basic firewall (optional)
              networking.firewall.enable = true;
              networking.firewall.allowedTCPPorts = [22]; # Open SSH port
            })
          ];
        };
      };
      nixosModules = {
        firecracker-pkgs = {...}: {
          nixpkgs.config.packageOverrides = pkgs: let
            firecrackerPackages = self.packages.${pkgs.system};
          in {
            inherit
              (firecrackerPackages)
              firecracker-kernel
              firecracker-containerd
              firecracker-rootfs
              firecracker-ctr
              firecracker
              ;
          };
        };
        knative = {...}: {
          imports = [
            {
              nixpkgs.config.packageOverrides = pkgs: {
                inherit (self.packages.${pkgs.system}) deploy-knative;
              };
            }
            self.nixosModules.k3s
            ./nix/modules/knative.nix
          ];
        };
        k3s = {...}: {
          imports = [
            self.nixosModules.firecracker-containerd
            ./nix/modules/k3s.nix
          ];
        };
        vhive = {...}: {
          imports = [
            ({...}: {
              nixpkgs.config.packageOverrides = pkgs: {
                inherit (self.packages.${pkgs.system}) vhive;
              };
            })
            ./nix/modules/vhive.nix
          ];
        };
        firecracker-containerd = {...}: {
          imports = [
            self.nixosModules.firecracker-pkgs
            ./nix/modules/firecracker-containerd.nix
          ];
        };
      };
    };
}
