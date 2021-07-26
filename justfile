
vhive_dir := invocation_directory() + "/../vhive"

# print this help
help: 
    just -l

# when the autoscaler overloads your system again
killvms:
    sudo pkill -SIGTERM firecracker

reset: 
    just make-incinerate
    just vhive-registry
    just make-deploy
    while [[ 24 -gt $(sudo -E kubectl get pod --all-namespaces | grep "Running" | wc -l) ]]; do sleep 1; done
    sleep 5
    just vhive-deployer

reset-notify:
    #!/bin/sh
    just reset
    sendtelegram "vhive resetted $?"

nixos-rebuild: 
    sudo nixos-rebuild switch --impure --override-input lambda-pirate ./.

make-incinerate:
    sudo -E make -C knative burn-down-cluster

make-deploy:
    CONFIG_ACCESSOR=cat VHIVE_CONFIG={{vhive_dir}}/configs sudo -E make -C knative deploy -j$(nproc)

# after cd ~/vhive && go install ./... you can run the deployer via:
vhive-deployer:
    sudo -E ~/go/bin/deployer -jsonFile {{vhive_dir}}/examples/deployer/functions.json -funcPath {{vhive_dir}}/configs/knative_workloads --endpointsFile /tmp/endpoints.json

vhive-deploy-local:
    sudo -E kn service apply helloworldlocal -f {{vhive_dir}}/configs/knative_workloads/helloworld_local.yaml

vhive-invoker-slow:
    ~/go/bin/invoker -time 20 --endpointsFile /tmp/endpoints.json

vhive-invoker-fast:
    ~/go/bin/invoker -rps 20 -time 20 --endpointsFile /tmp/endpoints.json

vhive-registry:
    #CONFIG_ACCESSOR=cat VHIVE_CONFIG=/home/peter/vhive/configs sudo -E make -C knative registry
    sudo ~/go/bin/registry -imageFile {{vhive_dir}}/examples/registry/images.txt -source docker://docker.io 
    #-destination docker://docker-registry.registry.svc.cluster.local.10.43.225.186.nip.io:5000

watch-pods-all:
    watch sudo -E kubectl get pod --all-namespaces

watch-pods:
    watch -n 0.5 sudo -E kubectl get pod

fcctr: 
    echo "image to container id mapping"
    sudo firecracker-ctr -n firecracker-containerd containers list
    echo "containerid/task to pid mapping: not host pid"
    sudo firecracker-ctr -n firecracker-containerd tasks ls

fcctr-delete:
    for i in {0..200}; do sudo firecracker-ctr -n firecracker-containerd containers delete $i; done

# proxy to remove all security from rest api
kube-proxy:
    sudo -E kubectl proxy &

# works
# curl -k "http://localhost:8001/apis/autoscaling/v1/horizontalpodautoscalers" | vim -

# didnt work
# curl -k "http://localhost:8001/apis/autoscaling/v1/namespaces/default/horizontalpodautoscalers/minio-deployment-877b8596f-4x9nc"

