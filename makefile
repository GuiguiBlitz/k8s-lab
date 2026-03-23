.PHONY: all install-bin setup-controller start-service configure-kubectl verify clean install-envoy-gateway install-storage

# Bootstrap the full cluster from scratch
all: install-bin setup-controller start-service configure-kubectl verify install-storage install-envoy-gateway

install-bin:
	curl -sSf https://get.k0s.sh | sudo sh

setup-controller:
	sudo k0s install controller --single

start-service:
	sudo k0s start
	@echo "Waiting 60 seconds for nodes to ready..."
	sleep 60

configure-kubectl:
	mkdir -p $(HOME)/.kube
	sudo k0s kubeconfig admin > $(HOME)/.kube/config
	chmod 600 $(HOME)/.kube/config

verify:
	sudo k0s kubectl get nodes
	KUBECONFIG=$(HOME)/.kube/config kubectl get nodes

clean:
	sudo k0s stop
	sudo k0s reset

# Install Rancher local-path-provisioner (provides the "local-path" StorageClass)
install-storage:
	kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
	kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Install Envoy Gateway and apply cluster-wide Gateway API resources
install-envoy-gateway:
	helm install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version v1.7.1 \
	  -n envoy-gateway-system \
	  --create-namespace
	kubectl apply -f cluster/
