Hometask 1

- Disabled the --cloud-provider=external option for kubelet, kube-apiserver, and kube-controller-manager.

- After removing this flag, the nginx pod started successfully.

Hometask 2.1

- Added static pod manifests for etcd, kube-apiserver, kube-controller-manager, and kube-scheduler.

- Disabled manual startup of these components in setup.sh — they are now launched automatically by kubelet as static pods.

- Increased the maxPods parameter for kubelet from 4 to 40.
