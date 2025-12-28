#!/bin/bash
while IFS='=' read -r key value; do
    # Skip empty lines and comments
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    encoded_value=$(printf "%s" "$value" | base64 | tr -d '\n')
    echo "SECRET_$key=$encoded_value";
done < .env > .env_encoded
