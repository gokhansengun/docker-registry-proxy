#! /bin/bash

set -Eeuo pipefail
trap "echo TRAPed signal" HUP INT QUIT TERM

#configure nginx DNS settings to match host, why must we do that nginx?
conf="resolver $(/usr/bin/awk 'BEGIN{ORS=" "} $1=="nameserver" {print $2}' /etc/resolv.conf) ipv6=off; # Avoid ipv6 addresses for now"
[ "$conf" = "resolver ;" ] && echo "no nameservers found" && exit 0
confpath=/etc/nginx/resolvers.conf
if [ ! -e $confpath ] || [ "$conf" != "$(cat $confpath)" ]
then
    echo "$conf" > $confpath
fi

# The list of SAN (Subject Alternative Names) for which we will create a TLS certificate.
ALLDOMAINS=""

# Interceptions map, which are the hosts that will be handled by the caching part.
# It should list exactly the same hosts we have created certificates for -- if not, Docker will get TLS errors, of course.
echo -n "" > /etc/nginx/docker.intercept.map

# Some hosts/registries are always needed, but others can be configured in env var REGISTRIES
for ONEREGISTRYIN in docker.caching.proxy.internal registry-1.docker.io auth.docker.io ${REGISTRIES}; do
    ONEREGISTRY=$(echo ${ONEREGISTRYIN} | xargs) # Remove whitespace
    echo "Adding certificate for registry: $ONEREGISTRY"
    ALLDOMAINS="${ALLDOMAINS},DNS:${ONEREGISTRY}"
    echo "${ONEREGISTRY} 127.0.0.1:443;" >> /etc/nginx/docker.intercept.map
done

# Clean the list and generate certificates.
export ALLDOMAINS=${ALLDOMAINS:1} # remove the first comma and export
/create_ca_cert.sh # This uses ALLDOMAINS to generate the certificates.

# Now handle the auth part.
echo -n "" > /etc/nginx/docker.auth.map

# Only configure auth registries if the env var contains values
if [ "$AUTH_REGISTRIES" ]; then
    # Ref: https://stackoverflow.com/a/47633817/219530
    AUTH_REGISTRIES_DELIMITER=${AUTH_REGISTRIES_DELIMITER:-" "}
    s=$AUTH_REGISTRIES$AUTH_REGISTRIES_DELIMITER
    auth_array=();
    while [[ $s ]]; do
        auth_array+=( "${s%%"$AUTH_REGISTRIES_DELIMITER"*}" );
        s=${s#*"$AUTH_REGISTRIES_DELIMITER"};
    done

    AUTH_REGISTRY_DELIMITER=${AUTH_REGISTRY_DELIMITER:-":"}

    for ONEREGISTRY in "${auth_array[@]}"; do
        s=$ONEREGISTRY$AUTH_REGISTRY_DELIMITER
        registry_array=();
        while [[ $s ]]; do
            registry_array+=( "${s%%"$AUTH_REGISTRY_DELIMITER"*}" );
            s=${s#*"$AUTH_REGISTRY_DELIMITER"};
        done
        AUTH_HOST="${registry_array[0]}"
        AUTH_USER="${registry_array[1]}"
        AUTH_PASS="${registry_array[2]}"
        AUTH_BASE64=$(echo -n ${AUTH_USER}:${AUTH_PASS} | base64 -w0 | xargs)
        echo "Adding Auth for registry '${AUTH_HOST}' with user '${AUTH_USER}'."
        echo "\"${AUTH_HOST}\" \"${AUTH_BASE64}\";" >> /etc/nginx/docker.auth.map
    done
fi

echo "" > /etc/nginx/docker.verify.ssl.conf
if [[ "a${VERIFY_SSL}" == "atrue" ]]; then
    cat << EOD > /etc/nginx/docker.verify.ssl.conf
    # We actually wanna be secure and avoid mitm attacks.
    # Fitting, since this whole thing is a mitm...
    # We'll accept any cert signed by a CA trusted by Mozilla (ca-certificates in alpine)
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 2;
EOD
    echo "Upstream SSL certificate verification enabled."
fi

# create default config for the caching layer to listen on 443.
echo "        listen 443 ssl default_server;" > /etc/nginx/caching.layer.listen
echo "error_log  /var/log/nginx/error.log warn;" > /etc/nginx/error.log.debug.warn

# Set Docker Registry cache size, by default, 32 GB ('32g')
CACHE_MAX_SIZE=${CACHE_MAX_SIZE:-32g}

# The cache directory. This can get huge. Better to use a Docker volume pointing here!
# Set to 32gb which should be enough
echo "proxy_cache_path /docker_mirror_cache levels=1:2 max_size=$CACHE_MAX_SIZE inactive=60d keys_zone=cache:10m use_temp_path=off;" > /etc/nginx/conf.d/cache_max_size.conf

# normally use non-debug version of nginx
NGINX_BIN="nginx"

if [[ "a${DEBUG}" == "atrue" ]]; then
  # in debug mode, change caching layer to listen on 444, so that mitmproxy can sit in the middle.
  echo "        listen 444 ssl default_server;" > /etc/nginx/caching.layer.listen

  echo "Starting in DEBUG MODE (mitmproxy)."
  echo "Run mitmproxy with reverse pointing to the same certs..."
  mitmweb --no-web-open-browser --web-iface 0.0.0.0 --web-port 8081 \
          --set keep_host_header=true --set ssl_insecure=true \
          --mode reverse:https://127.0.0.1:444 --listen-host 0.0.0.0 \
          --listen-port 443 --certs /certs/fullchain_with_key.pem \
          -w /ca/outfile &
  echo "Access mitmweb via http://127.0.0.1:8081/ "
fi

if [[ "a${DEBUG_NGINX}" == "atrue" ]]; then
  echo "Starting in DEBUG MODE (nginx)."
  echo "error_log  /var/log/nginx/error.log debug;" > /etc/nginx/error.log.debug.warn
  # use debug binary
  NGINX_BIN="nginx-debug"
fi

echo "Testing nginx config..."
${NGINX_BIN} -t

echo "Starting nginx! Have a nice day."
${NGINX_BIN} -g "daemon off;"
