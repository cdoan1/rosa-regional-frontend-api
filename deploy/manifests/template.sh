#!/bin/bash

sed 's/TARGET_GROUP_ARN/'${TARGET_GROUP_ARN}'/g' envoy-sidecar.yaml > envoy-sidecar.yaml.1
mv envoy-sidecar.yaml.1 envoy-sidecar.yaml

