#!/bin/bash
set -e
trap "cleanup $? $LINENO" EXIT

function cleanup {
  if [ "$?" != "0" ]; then
    echo "PLAYBOOK FAILED. See /var/log/stackscript.log for details."
    rm ${HOME}/.ssh/id_ansible_ed25519{,.pub}
    destroy
    exit 1
  fi
}

# constants
readonly REDIS_VERSION='7.0.7'
readonly ROOT_PASS=$(sudo cat /etc/shadow | grep root)
readonly LINODE_PARAMS=($(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .type,.region,.image))
readonly TAGS=$(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .tags)
readonly VARS_PATH="./group_vars/redis-sentinel/vars"

# utility functions
function destroy {
  if [ -n "${DISTRO}" ] && [ -n "${DATE}" ]; then
    ansible-playbook destroy.yml --extra-vars "instance_prefix=${DISTRO}-${DATE}"
  else
    ansible-playbook destroy.yml
  fi
}

function secrets {
  local SECRET_VARS_PATH="./group_vars/redis-sentinel/secret_vars"
  local VAULT_PASS=$(openssl rand -base64 32)
  local TEMP_ROOT_PASS=$(openssl rand -base64 32)
  local REDIS_PASSWORD=$(openssl rand -base64 32)
  echo "${VAULT_PASS}" > ./.vault-pass
  cat << EOF > ${SECRET_VARS_PATH}
`ansible-vault encrypt_string "${TEMP_ROOT_PASS}" --name 'root_pass'`
`ansible-vault encrypt_string "${TOKEN_PASSWORD}" --name 'token'`
`ansible-vault encrypt_string "${REDIS_PASSWORD}" --name 'redis_password'`
EOF
}

function ssh_key {
    ssh-keygen -o -a 100 -t ed25519 -C "ansible" -f "${HOME}/.ssh/id_ansible_ed25519" -q -N "" <<<y >/dev/null
    export ANSIBLE_SSH_PUB_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519.pub)
    export ANSIBLE_SSH_PRIV_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519)
    export SSH_KEY_PATH="${HOME}/.ssh/id_ansible_ed25519"
    chmod 700 ${HOME}/.ssh
    chmod 600 ${SSH_KEY_PATH}
    eval $(ssh-agent)
    ssh-add ${SSH_KEY_PATH}
    echo -e "\nprivate_key_file = ${SSH_KEY_PATH}" >> ansible.cfg
}

function lint {
  yamllint .
  ansible-lint
  flake8
}

function verify {
    ansible-playbook -i hosts verify.yml
    destroy
}

# production
function ansible:build {
  secrets
  ssh_key
  # write vars file
  sed 's/  //g' <<EOF > ${VARS_PATH}
  # linode vars
  ssh_keys: ${ANSIBLE_SSH_PUB_KEY}
  instance_prefix: ${INSTANCE_PREFIX}
  type: ${LINODE_PARAMS[0]}
  region: ${LINODE_PARAMS[1]}
  image: ${LINODE_PARAMS[2]}
  linode_tags: ${TAGS}
  # sudo user
  sudo_username: ${SUDO_USERNAME}
  redis_version: ${REDIS_VERSION}
  cluster_size: ${CLUSTER_SIZE}
  # ssl/tls
  country_name: ${COUNTRY_NAME}
  state_or_province_name: ${STATE_OR_PROVINCE}
  locality_name: ${LOCALITY_NAME}
  organization_name: ${ORGANIZATION_NAME}
  email_address: ${EMAIL_ADDRESS}
  ca_common_name: ${CA_COMMON_NAME}
  common_name: ${COMMON_NAME}
  # paths
  redis_cacert: '/etc/redis/tls/ca.crt'
  redis_cekey: '/etc/redis/tls/ca.key'
  redis_cert: '/etc/redis/tls/redis.crt'
  redis_key: '/etc/redis/tls/redis.key'
  redis_dh: '/etc/redis/tls/redis.dh'
EOF
}

function ansible:deploy {
  ansible-playbook provision.yml
  ansible-playbook -i hosts site.yml --extra-vars "root_password=${ROOT_PASS} add_keys_prompt=${ADD_SSH_KEYS}"
}

# testing
function test:build {
  # write vars file
  sed 's/  //g' <<EOF > ${VARS_PATH}
  # linode vars
  ssh_keys: ssh-rsa AAAA_valid_public_ssh_key_123456785== user@their-computer
  # Deployment vars
  instance_prefix: redis
  type: g6-standard-2
  region: us-southeast
  image: linode/debian11
  linode_tags: POC
  # sudo user
  sudo_username: admin
  redis_version: ${REDIS_VERSION} #do not update
  cluster_size: 3
  # ssl/tls
  country_name: US
  state_or_province_name: Pennsylvania
  locality_name: Philadelphia
  organization_name: Linode
  email_address: test@linode.com
  ca_common_name: Redis CA
  common_name: linode.com
  # paths
  redis_cacert: '/etc/redis/tls/ca.crt'
  redis_cekey: '/etc/redis/tls/ca.key'
  redis_cert: '/etc/redis/tls/redis.crt'
  redis_key: '/etc/redis/tls/redis.key'
  redis_dh: '/etc/redis/tls/redis.dh'  
EOF
  cat "./group_vars/redis-sentinel/vars"
  mkdir -p ${HOME}/.ssh
  echo ${ACCOUNT_SSH_KEYS} >> ${HOME}/.ssh/authorized_keys
  secrets
  ssh_key
}

function test:deploy {
  export DISTRO="${1}"
  export DATE="$(date '+%Y-%m-%d-%H%M%S')"
  ansible-playbook provision.yml --extra-vars "ssh_keys=${HOME}/.ssh/id_ansible_ed25519.pub instance_prefix=${DISTRO}-${DATE} image=linode/${DISTRO}"
  ansible-playbook -i hosts site.yml --extra-vars "root_password=${ROOT_PASS}  add_keys_prompt=yes"
  verify
}

# main
case $1 in
    ansible:build) "$@"; exit;;
    ansible:deploy) "$@"; exit;;
    test:build) "$@"; exit;;
    test:deploy) "$@"; exit;;
esac
