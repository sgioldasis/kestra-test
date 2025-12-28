#!/bin/bash

# Kestra Local Kubernetes Installation Script
set -e

NAMESPACE="kestra"
HELM_REPO_NAME="kestra"
HELM_REPO_URL="https://helm.kestra.io"
CHART_NAME="kestra/kestra-starter"
RELEASE_NAME="kestra"
APP_YAML="application.yaml"
K8S_VARS_YAML="application-k8s.yaml"
ENV_ENCODED=".env_encoded"
FLOWS_DIR="flows"
FLOWS_CONFIGMAP="kestra-local-flows"
PORT=8080

log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

check_prerequisites() {
    log "Checking prerequisites..."
    for cmd in kubectl helm ruby; do
        command -v $cmd &> /dev/null || error "$cmd is not installed."
    done
}

setup_helm_repo() {
    log "Setting up Kestra Helm repository..."
    helm repo add $HELM_REPO_NAME $HELM_REPO_URL --force-update
    helm repo update
}

prepare_flows() {
    if [ -d "$FLOWS_DIR" ]; then
        log "Updating ConfigMap '$FLOWS_CONFIGMAP'..."
        kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
        kubectl create configmap $FLOWS_CONFIGMAP --from-file="$FLOWS_DIR" -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    fi
}

generate_k8s_values() {
    log "Generating Kubernetes configuration..."
    cat <<EOF > gen_values.rb
require "yaml"
begin
  values = {
    "kestra" => {
      "configurations" => { "application" => {} },
      "common" => { 
        "extraEnv" => [{ "name" => "DOCKER_HOST", "value" => "unix:///dind/docker.sock" }],
        "extraVolumes" => [], "extraVolumeMounts" => [], "initContainers" => []
      },
      "startupProbe" => { "failureThreshold" => 300 },
      "livenessProbe" => { "failureThreshold" => 10 }
    }
  }

  if File.exist?("$APP_YAML")
    app_config = YAML.load_file("$APP_YAML") || {}
    app_config.delete("datasources")
    if app_config["kestra"]
      app_config["kestra"].delete("repository"); app_config["kestra"].delete("storage"); app_config["kestra"].delete("queue")
      app_config["kestra"]["tutorialFlows"] ||= {}; app_config["kestra"]["tutorialFlows"]["enabled"] = false
      app_config["kestra"]["tasks"] ||= {}; app_config["kestra"]["tasks"]["tmpDir"] ||= {}
      app_config["kestra"]["tasks"]["tmpDir"]["path"] = "/tmp/kestra-wd/tmp"
    end
    
    app_config["kestra"]["plugins"] ||= {}
    app_config["kestra"]["plugins"]["configurations"] ||= {}
    app_config["kestra"]["plugins"]["configurations"]["io.kestra.plugin.scripts.runner.docker.Docker"] = {
      "host-directory" => "/tmp", "file-server-port" => 10080, "file-server-address" => "0.0.0.0", "volumes" => ["/tmp:/tmp"]
    }
    
    app_config["micronaut"] ||= {}; app_config["micronaut"]["io"] ||= {}; app_config["micronaut"]["io"]["watch"] ||= {}
    app_config["micronaut"]["io"]["watch"]["enabled"] = true; app_config["micronaut"]["io"]["watch"]["paths"] = ["/flows_folder"]
    values["kestra"]["configurations"]["application"] = app_config
  end

  env_vars = {}
  ENV["GOOGLEAI_API_KEY"] && (env_vars["GOOGLEAI_API_KEY"] = ENV["GOOGLEAI_API_KEY"])
  File.exist?("$ENV_ENCODED") && File.readlines("$ENV_ENCODED").each { |l| next if l.strip.empty? || l.start_with?("#"); k, v = l.strip.split("=", 2); env_vars[k] = v if k && v }
  env_vars.each { |n, v| values["kestra"]["common"]["extraEnv"] << { "name" => n, "value" => v } }

  if Dir.exist?("$FLOWS_DIR")
    values["kestra"]["common"]["extraVolumes"] << { "name" => "flows-configmap", "configMap" => { "name" => "$FLOWS_CONFIGMAP" } }
    values["kestra"]["common"]["extraVolumes"] << { "name" => "flows-writable", "emptyDir" => {} }
    values["kestra"]["common"]["extraVolumeMounts"] << { "name" => "flows-writable", "mountPath" => "/flows_folder" }
    values["kestra"]["common"]["initContainers"] << {
      "name" => "copy-flows", "image" => "busybox", "command" => ["sh", "-c", "cp -RL /src/* /dst/"],
      "volumeMounts" => [{ "name" => "flows-configmap", "mountPath" => "/src" }, { "name" => "flows-writable", "mountPath" => "/dst" }]
    }
  end
  File.write("$K8S_VARS_YAML", values.to_yaml)
rescue => e; STDERR.puts "Error: #{e.message}"; exit 1; end
EOF
    ruby gen_values.rb && rm gen_values.rb
}

install_kestra() {
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    HELM_OPTS=("--namespace" "$NAMESPACE" "--wait" "--timeout" "10m0s")
    [ -s "$K8S_VARS_YAML" ] && HELM_OPTS+=("-f" "$K8S_VARS_YAML")
    helm upgrade --install $RELEASE_NAME $CHART_NAME "${HELM_OPTS[@]}"
}

start_port_forward() {
    lsof -ti :$PORT | xargs kill -9 > /dev/null 2>&1 || true
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=standalone -n $NAMESPACE --timeout=300s
    (kubectl port-forward svc/kestra-starter $PORT:8080 -n $NAMESPACE > /dev/null 2>&1 &)
}

check_prerequisites
setup_helm_repo
prepare_flows
generate_k8s_values
install_kestra
start_port_forward
log "Kestra ready at http://localhost:$PORT"
