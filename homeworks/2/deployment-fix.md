### Problem Overview
Pods fail to schedule due to the "Too many pods" error, which occurs when the number of pods on a node exceeds the kubelet's `max-pods` configuration limit.

### Resolution Steps

1. Inspect the Deployment and Pod
Firstly, examine the deployment and pod details to identify the issue:

```bash
sudo kubebuilder/bin/kubectl describe deploy demo
sudo kubebuilder/bin/kubectl describe pod demo-dfdb5969b-7qxqw
```

2. Verify the Scheduling Failure
Look for the `FailedScheduling` event in the pod description. You should see output similar to:

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  22s   default-scheduler  0/1 nodes are available: 1 Too many pods. preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

3. Stop the Kubelet Process
Terminate the running kubelet process:

```bash
sudo pkill -f kubelet
```

4. Restart Kubelet with Increased Pod Limit
Restart the kubelet process with an adjusted `max-pods` configuration (increased to 20):

```bash
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet \
    --kubeconfig=/var/lib/kubelet/kubeconfig \
    --config=/var/lib/kubelet/config.yaml \
    --root-dir=/var/lib/kubelet \
    --cert-dir=/var/lib/kubelet/pki \
    --tls-cert-file=/var/lib/kubelet/pki/kubelet.crt \
    --tls-private-key-file=/var/lib/kubelet/pki/kubelet.key \
    --hostname-override=$(hostname) \
    --pod-infra-container-image=registry.k8s.io/pause:3.10 \
    --node-ip=$HOST_IP \
    --cloud-provider=external \
    --cgroup-driver=cgroupfs \
    --max-pods=20 \
    --v=1 &
```

5. Verify Successful Pod Scheduling
Confirm that the pods are now scheduled and running successfully:

```bash
sudo kubectl get pods
```

Expected output:
```
NAME                   READY   STATUS    RESTARTS   AGE
demo-dfdb5969b-lqq6x   1/1     Running   0          2m5s
demo-dfdb5969b-tcl2z   1/1     Running   0          2m5s
demo-dfdb5969b-zct9c   1/1     Running   0          2m5s
```

### Summary
By increasing the kubelet's `max-pods` limit from the default value to 20, the node can now accommodate more pods, resolving the 
scheduling failure. Adjust the `max-pods` value based on your node's capacity and workload requirements.