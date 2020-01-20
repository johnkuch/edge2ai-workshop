#!/bin/bash

KEYTABS_DIR=/keytabs
KAFKA_CLIENT_PROPERTIES=${KEYTABS_DIR}/kafka-client.properties

function is_kerberos_enabled() {
  if [ -d $KEYTABS_DIR ]; then
    echo yes
  else
    echo no
  fi
}

# Often yum connection to Cloudera repo fails and causes the instance create to fail.
# yum timeout and retries options don't see to help in this type of failure.
# We explicitly retry a few times to make sure the build continues when these timeouts happen.
function yum_install() {
  local packages=$@
  local retries=10
  while true; do
    set +e
    yum install -d1 -y ${packages}
    RET=$?
    set -e
    if [[ ${RET} == 0 ]]; then
      break
    fi
    retries=$((retries - 1))
    if [[ ${retries} -lt 0 ]]; then
      echo 'YUM install failed!'
      exit 1
    else
      echo 'Retrying YUM...'
    fi
  done
}

function get_homedir() {
  local username=$1
  getent passwd $username | cut -d: -f6
}

function load_stack() {
  local namespace=$1
  local base_dir=${2:-$BASE_DIR}
  local is_local=${3:-no}
  if [ -e $base_dir/stack.${namespace}.sh ]; then
    source $base_dir/stack.${namespace}.sh
  else
    source $base_dir/stack.sh
  fi
  export CM_SERVICES=$CM_SERVICES
  export CM_SERVICES=$(echo "$CM_SERVICES" | tr "[a-z]" "[A-Z]")
  export CM_VERSION CDH_VERSION CDH_BUILD CDH_PARCEL_REPO ANACONDA_VERSION ANACONDA_PARCEL_REPO
  export ANACONDA_VERSION CDH_BUILD CDH_PARCEL_REPO CDH_VERSION CDSW_PARCEL_REPO CDSW_BUILD
  export CFM_PARCEL_REPO CFM_VERSION CM_VERSION CSA_PARCEL_REPO CSP_PARCEL_REPO FLINK_BUILD
  export SCHEMAREGISTRY_BUILD STREAMS_MESSAGING_MANAGER_BUILD

  ENABLE_KERBEROS=$(echo "${ENABLE_KERBEROS:-NO}" | tr a-z A-Z)
  if [ "$ENABLE_KERBEROS" == "YES" -o "$ENABLE_KERBEROS" == "TRUE" -o "$ENABLE_KERBEROS" == "1" ]; then
    ENABLE_KERBEROS=yes
    if [ "$is_local" != "local" ]; then
      mkdir -p $KEYTABS_DIR
    fi
  else
    ENABLE_KERBEROS=no
  fi
}

function auth() {
  local princ=$1
  local username=${princ%%/*}
  username=${username%%@*}
  local keytab_file=${KEYTABS_DIR}/${username}.keytab
  if [ -f $keytab_file ]; then
    kinit -kt $keytab_file $princ
    export KAFKA_OPTS="-Djava.security.auth.login.config=${KEYTABS_DIR}/jaas.conf"
  else
    export HADOOP_USER_NAME=$username
  fi
}

function unauth() {
  if [ -d ${KEYTABS_DIR} ]; then
    kdestroy
    unset KAFKA_OPTS
  else
    unset HADOOP_USER_NAME
  fi
}

function add_kerberos_principal() {
  local princ=$1
  local username=${princ%%/*}
  username=${username%%@*}
  if [ "$(getent passwd $username > /dev/null && echo exists || echo does_not_exist)" == "does_not_exist" ]; then
    useradd -U $username
  fi
  (sleep 1 && echo -e "supersecret1\nsupersecret1") | /usr/sbin/kadmin.local -q "addprinc $princ"
  mkdir -p ${KEYTABS_DIR}
  echo -e "addent -password -p $princ -k 0 -e aes256-cts\nsupersecret1\nwrite_kt ${KEYTABS_DIR}/$username.keytab" | ktutil
  chmod 444 ${KEYTABS_DIR}/$username.keytab
}

function install_kerberos() {
  krb_server=$(hostname -f)
  krb_realm=WORKSHOP.COM
  krb_realm_lc=$( echo $krb_realm | tr A-Z a-z )

  # Install Kerberos packages
  yum -y install krb5-libs krb5-server krb5-workstation

  # Ensure entropy
  yum -y install rng-tools
  systemctl start rngd
  cat /proc/sys/kernel/random/entropy_avail

  # Update krb5.conf
  replace_pattern="s/kerberos.example.com/$krb_server/g;s/EXAMPLE.COM/$krb_realm/g;s/example.com/$krb_realm_lc/g;s/^#\(.*[={}]\)/\1/;/KEYRING/ d"
  sed -i.bak "$replace_pattern" /etc/krb5.conf
  ls -l /etc/krb5.conf /etc/krb5.conf.bak
  diff  /etc/krb5.conf /etc/krb5.conf.bak || true

  # Update kdc.conf
  replace_pattern="s/EXAMPLE.COM = {/$krb_realm = {\n  max_renewable_life = 7d 0h 0m 0s/"
  sed -i.bak "$replace_pattern" /var/kerberos/krb5kdc/kdc.conf
  ls -l /var/kerberos/krb5kdc/kdc.conf /var/kerberos/krb5kdc/kdc.conf.bak
  diff  /var/kerberos/krb5kdc/kdc.conf /var/kerberos/krb5kdc/kdc.conf.bak || true

  # Create database
  /usr/sbin/kdb5_util create -s -P supersecret1

  # Update kadm5.acl
  replace_pattern="s/kerberos.example.com/$krb_server/g;s/EXAMPLE.COM/$krb_realm/g;s/example.com/$krb_realm_lc/g;"
  sed -i.bak "$replace_pattern" /var/kerberos/krb5kdc/kadm5.acl
  ls -l /var/kerberos/krb5kdc/kadm5.acl /var/kerberos/krb5kdc/kadm5.acl.bak
  diff /var/kerberos/krb5kdc/kadm5.acl /var/kerberos/krb5kdc/kadm5.acl.bak || true

  # Create CM principal
  add_kerberos_principal scm/admin

  # Set maxrenewlife for krbtgt
  # IMPORTANT: You must explicitly set this, even if the default is already set correctly.
  #            Failing to do so will cause some services to fail.

  kadmin.local -q "modprinc -maxrenewlife 7day krbtgt/$krb_realm@$krb_realm"

  # Start Kerberos
  systemctl enable krb5kdc
  systemctl enable kadmin
  systemctl start krb5kdc
  systemctl start kadmin

  # Add principals
  add_kerberos_principal hdfs
  add_kerberos_principal yarn
  add_kerberos_principal kafka
  add_kerberos_principal flink

  add_kerberos_principal workshop
  add_kerberos_principal alice
  add_kerberos_principal bob

  # Create a client properties file for Kafka clients
  cat >> ${KAFKA_CLIENT_PROPERTIES} <<EOF
security.protocol=SASL_PLAINTEXT
sasl.kerberos.service.name=kafka
EOF

  # Create a jaas.conf file
  cat >> ${KEYTABS_DIR}/jaas.conf <<EOF
KafkaClient {
com.sun.security.auth.module.Krb5LoginModule required
useTicketCache=true;
};
EOF

}
