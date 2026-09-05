#!/bin/bash -ex

helm --kubeconfig ../kube_config_cluster.yml install nfs-sc ./nfs-subdir-external-provisioner-4.0.18.tgz -f ./nfs-sc-values.yaml
kubectl --kubeconfig ../kube_config_cluster.yml patch storageclass nfs-sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
