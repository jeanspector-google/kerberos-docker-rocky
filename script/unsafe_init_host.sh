#!/usr/bin/env bash
#
# init.sh
#
# Init docker containers for kerberos cluster.

cd "$(dirname "$0")"
cd ..

source .env.values

suffix_realm=$(echo "${REALM_KRB5}" | sed 's/\./-/g' | tr [:upper:] [:lower:])
kdc_server_container="${PREFIX_KRB5}-kdc-server-${suffix_realm}"
service_container="${PREFIX_KRB5}-service-${suffix_realm}"
machine_container="${PREFIX_KRB5}-machine-${suffix_realm}"

echo "=== Init ${kdc_server_container} docker container ==="
docker exec "${kdc_server_container}" /bin/bash -c "
# Create users alice as admin and bob as normal user
# and add principal for the service
cat << EOF  | kadmin.local
add_principal -pw alice \"alice/admin@${REALM_KRB5}\"
add_principal -pw bob \"bob@${REALM_KRB5}\"
add_principal -randkey \"host/${service_container}.${DOMAIN_CONTAINER}@${REALM_KRB5}\"
ktadd -k /etc/krb5-service.keytab -norandkey \"host/${service_container}.${DOMAIN_CONTAINER}@${REALM_KRB5}\"
ktadd -k /etc/bob.keytab -norandkey \"bob@${REALM_KRB5}\"
listprincs
quit
EOF
"

echo "=== Copy keytabs to ${service_container}, ${machine_container}, and localhost ==="
tmp_folder="$(mktemp -d)"
docker cp "${kdc_server_container}":/etc/krb5-service.keytab "${tmp_folder}/krb5-service.keytab"
docker cp "${kdc_server_container}":/etc/bob.keytab "${tmp_folder}/bob.keytab"
docker cp "${machine_container}":/etc/krb5.conf "${tmp_folder}/krb5.conf"
docker cp "${tmp_folder}/krb5-service.keytab" "${service_container}":/etc/krb5.keytab
sudo cp "${tmp_folder}/krb5-service.keytab" /etc/krb5.keytab

diff -q "${tmp_folder}/krb5.conf" /etc/krb5.conf
if [ $? -ne 0 ]; then
  echo Updating krb.conf
  TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
  mv /etc/krb5.conf /etc/krb5.conf.$TIMESTAMP
  sudo cp "${tmp_folder}/krb5.conf" /etc/krb5.conf
fi

cp "${tmp_folder}/bob.keytab" /tmp/bob.keytab
rm -vrf "${tmp_folder}"


echo "=== Init localhost ==="

IP_ADDR=$(docker inspect krb5-kdc-server-example-com --format '{{ range.NetworkSettings.Networks}}{{print .IPAddress}}{{end}}')
HOST_NAMES=$(docker inspect krb5-kdc-server-example-com --format '{{ range.NetworkSettings.Networks}}{{range $i, $e := .DNSNames}}{{if gt $i 0}}{{print " "}}{{end}}{{if lt $i 2}}{{print $e}}{{end}}{{end}}{{end}}')
HOSTS_ENTRY=$(docker exec -ti krb5-kdc-server-example-com grep kdc-server /etc/hosts | tr -d '\r')

echo "Looking for /etc/hosts entry: '$HOSTS_ENTRY'"
grep -q "$HOSTS_ENTRY" /etc/hosts
if [ $? -ne 0 ]; then
	echo "Adding /etc/hosts entry"
	echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts
fi

echo '* Kerberos password authentication:'
until echo bob | kinit bob@${REALM_KRB5}; do
  echo Waiting for kerberos server started ...
  sleep 1
done

echo '* Kerberos keytab authentication:'
kinit -kt /tmp/bob.keytab bob@${REALM_KRB5} && echo OK || (echo KO && exit 1)

echo '* Kerberos tickets cache:'
klist

#echo "=== Init GSS API for Java Client/Server ==="
#cd gssapi-java/
#
#mvn --settings=settings.xml install -Dmaven.test.skip=true
#
#docker cp gss-client/target/gss-client-1.0-SNAPSHOT-jar-with-dependencies.jar "${machine_container}":/root/client.jar
#docker cp gss-client/config/jaas-krb5.conf "${machine_container}":/root/jaas-krb5.conf
#docker cp gss-client/script/client-gss-java.sh "${machine_container}":/root/client-gss-java.sh

#docker cp gss-server/target/gss-server-1.0-SNAPSHOT-jar-with-dependencies.jar "${service_container}":/root/server.jar
#docker cp gss-server/config/jaas-krb5.conf "${service_container}":/root/jaas-krb5.conf
#docker cp gss-server/script/server-gss-java.sh "${service_container}":/root/server-gss-java.sh
